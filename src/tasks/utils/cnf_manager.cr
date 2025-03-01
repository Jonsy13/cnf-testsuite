# coding: utf-8
require "totem"
require "colorize"
require "crinja"
require "./types/cnf_testsuite_yml_type.cr"
require "helm"
require "git_client"
require "uuid"
require "./points.cr"
require "./task.cr"
require "./config.cr"
require "airgap"
require "tar"
require "./image_prepull.cr"
require "./generate_config.cr"
require "log"

module CNFManager

  # TODO: figure out recursively check for unmapped json and warn on that
  # https://github.com/Nicolab/crystal-validator#check
  def self.validate_cnf_testsuite_yml(config)
    ccyt_validator = nil
    valid = true

    begin
      ccyt_validator = CnfTestSuiteYmlType.from_json(config.settings.to_json)
    rescue ex
      valid = false
      Log.error { "✖ ERROR: cnf_testsuite.yml field validation error.".colorize(:red) }
      Log.error { " please check info in the the field name near the text 'CnfTestSuiteYmlType#' in the error below".colorize(:red) }
      Log.error { ex.message }
      ex.backtrace.each do |x|
        Log.error { x }
      end
    end

    unmapped_keys_warning_msg = "WARNING: Unmapped cnf_testsuite.yml keys. Please add them to the validator".colorize(:yellow)
    unmapped_subkeys_warning_msg = "WARNING: helm_repository is unset or has unmapped subkeys. Please update your cnf_testsuite.yml".colorize(:yellow)

    if ccyt_validator && !ccyt_validator.try &.json_unmapped.empty?
      warning_output = [unmapped_keys_warning_msg] of String | Colorize::Object(String)
      warning_output.push(ccyt_validator.try &.json_unmapped.to_s)
      if warning_output.size > 1
        Log.warn { warning_output.join("\n") }
      end
    end

    #TODO Differentiate between unmapped subkeys or unset top level key.
    if ccyt_validator && !ccyt_validator.try &.helm_repository.try &.json_unmapped.empty?
      root = {} of String => (Hash(String, JSON::Any) | Nil)
      root["helm_repository"] = ccyt_validator.try &.helm_repository.try &.json_unmapped

      warning_output = [unmapped_subkeys_warning_msg] of String | Colorize::Object(String)
      warning_output.push(root.to_s)
      if warning_output.size > 1
        Log.warn { warning_output.join("\n") }
      end
    end

    { valid, warning_output }
  end


  # Applies a block to each cnf resource
  #
  # ```
  # CNFManager.cnf_workload_resources(args, config) {|cnf_config, resource| #your code}
  # ```
  def self.cnf_workload_resources(args, config, &block)
    destination_cnf_dir = config.cnf_config[:destination_cnf_dir]
    yml_file_path = config.cnf_config[:yml_file_path]
    helm_directory = config.cnf_config[:helm_directory]
    manifest_directory = config.cnf_config[:manifest_directory]
    release_name = config.cnf_config[:release_name]
    helm_chart_path = config.cnf_config[:helm_chart_path]
    manifest_file_path = config.cnf_config[:manifest_file_path]
    test_passed = true

    install_method = self.cnf_installation_method(config)
    Log.debug { "install_method: #{install_method}" }
    template_ymls = [] of YAML::Any
    case install_method[0]
    when Helm::InstallMethod::HelmChart, Helm::InstallMethod::HelmDirectory
      Helm.generate_manifest_from_templates(release_name,
                                            helm_chart_path,
                                            manifest_file_path)
      template_ymls = Helm::Manifest.parse_manifest_as_ymls(manifest_file_path)
    when Helm::InstallMethod::ManifestDirectory
    # if release_name.empty? # no helm chart
      template_ymls = Helm::Manifest.manifest_ymls_from_file_list(Helm::Manifest.manifest_file_list( destination_cnf_dir + "/" + manifest_directory))
    # else
    end
    resource_ymls = Helm.all_workload_resources(template_ymls)
		resource_resp = resource_ymls.map do | resource |
      resp = yield resource
      Log.debug { "cnf_workload_resource yield resp: #{resp}" }
      resp
    end

    resource_resp
  end

  #test_passes_completely = workload_resource_test do | cnf_config, resource, container, initialized |
  def self.workload_resource_test(args, config,
                                  check_containers = true,
                                  check_service = false,
                                  &block  : (NamedTuple(kind: YAML::Any, name: YAML::Any),
                                             JSON::Any, JSON::Any, Bool | Nil) -> Bool | Nil)
            # resp = yield resource, container, volumes, initialized
    test_passed = true
    resource_ymls = cnf_workload_resources(args, config) do |resource|
      resource
    end
    resource_names = Helm.workload_resource_kind_names(resource_ymls)
    Log.info { "resource names: #{resource_names}" }
    if resource_names && resource_names.size > 0
      initialized = true
    else
      Log.error { "no resource names found" }
      initialized = false
    end
    # todo check to see if following 'resource' variable is conflicting with above resource variable
		resource_names.each do | resource |
			Log.for("verbose").debug { resource.inspect } if check_verbose(args)
			volumes = KubectlClient::Get.resource_volumes(resource[:kind].as_s, resource[:name].as_s)
      Log.for("verbose").debug { "check_service: #{check_service}" } if check_verbose(args)
      Log.for("verbose").debug { "check_containers: #{check_containers}" } if check_verbose(args)
      case resource[:kind].as_s.downcase
      when "service"
        if check_service
          Log.info { "checking service: #{resource}" }
          resp = yield resource, JSON.parse(%([{}])), volumes, initialized
          Log.debug { "yield resp: #{resp}" }
          # if any response is false, the test fails
          test_passed = false if resp == false
        end
      else
				containers = KubectlClient::Get.resource_containers(resource[:kind].as_s, resource[:name].as_s)
				if check_containers
					containers.as_a.each do |container|
						resp = yield resource, container, volumes, initialized
						Log.debug { "yield resp: #{resp}" }
						# if any response is false, the test fails
						test_passed = false if resp == false
					end
				else
					resp = yield resource, containers, volumes, initialized
					Log.debug { "yield resp: #{resp}" }
					# if any response is false, the test fails
					test_passed = false if resp == false
				end
      end
		end
    Log.debug { "workload resource test intialized: #{initialized} test_passed: #{test_passed}" }
    initialized && test_passed
  end

  def self.cnf_installed?
    Log.info { "cnf_config_list" }
    find_cmd = "find #{CNF_DIR}/* -name '#{CONFIG_FILE}'"
    Log.info { "find: #{find_cmd}" }
    Process.run(
      find_cmd,
      shell: true,
      output: find_stdout = IO::Memory.new,
      error: find_stderr = IO::Memory.new
    )

    cnf_testsuite = find_stdout.to_s.split("\n").select{ |x| x.empty? == false }
    Log.info { "find response: #{cnf_testsuite}" }
    if cnf_testsuite.size == 0
      false
    else
      true
    end
  end

  def self.cnf_config_list(silent=false)
    Log.info { "cnf_config_list" }
    find_cmd = "find #{CNF_DIR}/* -name \"#{CONFIG_FILE}\""
    Log.info { "find: #{find_cmd}" }
    Process.run(
      find_cmd,
      shell: true,
      output: find_stdout = IO::Memory.new,
      error: find_stderr = IO::Memory.new
    )

    cnf_testsuite = find_stdout.to_s.split("\n").select{ |x| x.empty? == false }
    Log.info { "find response: #{cnf_testsuite}" }
    if cnf_testsuite.size == 0 && !silent
      raise "No cnf_testsuite.yml found! Did you run the setup task?"
    end
    cnf_testsuite
  end

  def self.destination_cnfs_exist?
    cnf_config_list(silent=true).size > 0
  end

  def self.parsed_config_file(path)
    Log.info { "parsed_config_file: #{path}" }
    if path && path.empty?
      raise "No cnf_testsuite.yml found in #{path}!"
    end
    Totem.from_file "#{path}"
  end

  def self.sample_testsuite_yml(sample_dir)
    Log.info { "sample_testsuite_yml sample_dir: #{sample_dir}" }
    find_cmd = "find #{sample_dir}/* -name \"cnf-testsuite.yml\""
    Process.run(
      find_cmd,
      shell: true,
      output: find_stdout = IO::Memory.new,
      error: find_stderr = IO::Memory.new
    )
    cnf_testsuite = find_stdout.to_s.split("\n")[0]
    if cnf_testsuite.empty?
      raise "No cnf_testsuite.yml found in #{sample_dir}!"
    end
    Totem.from_file "./#{cnf_testsuite}"
  end

  def self.path_has_yml?(config_path)
    if config_path =~ /\.yml/
      true
    else
      false
    end
  end

  def self.config_from_path_or_dir(cnf_path_or_dir)
    if path_has_yml?(cnf_path_or_dir)
      config_file = File.dirname(cnf_path_or_dir)
      config = sample_testsuite_yml(config_file)
    else
      config_file = cnf_path_or_dir
      config = sample_testsuite_yml(config_file)
    end
    return config
  end

  # if passed a directory, adds cnf-testsuite.yml to the string
  def self.ensure_cnf_testsuite_yml_path(path : String)
    Log.info { "ensure_cnf_testsuite_yml_path" }
    if path_has_yml?(path)
      yml = path
    else
      yml = path + "/cnf-testsuite.yml"
    end
  end

  def self.ensure_cnf_testsuite_dir(path : String)
    Log.info { "ensure_cnf_testsuite_yml_dir" }
    if path_has_yml?(path)
      dir = File.dirname(path)
    else
      dir = path
    end
    dir + "/"
  end

  def self.release_name?(config)
    release_name = optional_key_as_string(config, "release_name").split(" ")[0]
    if release_name.empty?
      false
    else
      true
    end
  end

  def self.exclusive_install_method_tags?(config)
    installation_type_count = ["helm_chart", "helm_directory", "manifest_directory"].reduce(0) do |acc, install_type|
      begin
        test_tag = config[install_type]
        Log.debug { "install type count install_type: #{install_type}" }
        if install_type.empty?
          acc
        else
          acc = acc + 1
        end
      rescue ex
        Log.debug { "install_type: #{install_type} not found in #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}" }
        acc
      end
    end
    Log.debug { "installation_type_count: #{installation_type_count}" }
    if installation_type_count > 1
      false
    else
      true
    end
  end

  # todo move this to the helm module and use the helm enumeration
  def self.install_method_by_config_src(config_src : String, airgapped=false, generate_tar_mode=false)
    Log.info { "install_method_by_config_src" }
    Log.info { "config_src: #{config_src}" }
    helm_chart_file = "#{config_src}/#{Helm::CHART_YAML}"
    Log.info { "looking for potential helm_chart_file: #{helm_chart_file}: file exists?: #{File.exists?(helm_chart_file)}" }

    if !Dir.exists?(config_src) 
      Log.info { "install_method_by_config_src helm_chart selected" }
      Helm::InstallMethod::HelmChart
    elsif File.exists?(helm_chart_file)
      Log.info { "install_method_by_config_src helm_directory selected" }
      Helm::InstallMethod::HelmDirectory
    # elsif generate_tar_mode && KubectlClient::Apply.validate(config_src) # just because we are in generate tar mode doesn't mean we have a K8s cluster
    elsif Dir.exists?(config_src) 
      Log.info { "install_method_by_config_src manifest_directory selected" }
      Helm::InstallMethod::ManifestDirectory
    else
      puts "Error: #{config_src} is neither a helm_chart, helm_directory, or manifest_directory.".colorize(:red)
      exit 1
    end
  end

  def self.cnf_installation_method(config : CNFManager::Config) : Tuple(Helm::InstallMethod, String)
    Log.info { "cnf_installation_method config : CNFManager::Config" }
    Log.info { "config_cnf_config: #{config.cnf_config}" }
    yml_file_path = config.cnf_config[:source_cnf_file]
    parsed_config_file = CNFManager.parsed_config_file(yml_file_path)
    cnf_installation_method(parsed_config_file)
  end

  #Determine, for cnf, whether a helm chart, helm directory, or manifest directory is being used for installation
  def self.cnf_installation_method(config : Totem::Config) : Tuple(Helm::InstallMethod, String)
    Log.info { "cnf_installation_method" }
    Log.info { "cnf_installation_method config: #{config}" }
    Log.info { "cnf_installation_method config: #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}" }
    helm_chart = optional_key_as_string(config, "helm_chart")
    helm_directory = optional_key_as_string(config, "helm_directory")
    manifest_directory = optional_key_as_string(config, "manifest_directory")
    release_name = optional_key_as_string(config, "release_name")
    full_helm_directory = ""
    full_manifest_directory = ""
    Log.info { "release_name: #{release_name}" }
    Log.info { "helm_directory: #{helm_directory}" }
    Log.info { "manifest_directory: #{manifest_directory}" }
    if Dir.exists?(helm_directory) 
      Log.info { "Change helm_directory relative path into full path" }
      full_helm_directory = Path[helm_directory].expand.to_s
    elsif Dir.exists?(manifest_directory)
      Log.info { "Change manifest_directory relative path into full path" }
      full_manifest_directory = Path[manifest_directory].expand.to_s
    else
      Log.info { "Building helm_directory and manifest_directory full paths" }
      full_helm_directory = Path[CNF_DIR + "/" + release_name + "/" + helm_directory].expand.to_s
      full_manifest_directory = Path[CNF_DIR + "/" + release_name + "/" + manifest_directory].expand.to_s
    end

    Log.info { "full_helm_directory: #{full_helm_directory} exists? #{Dir.exists?(full_helm_directory)}" }
    Log.info { "full_manifest_directory: #{full_manifest_directory} exists? #{Dir.exists?(full_manifest_directory)}" }

    unless CNFManager.exclusive_install_method_tags?(config)
      puts "Error: Must populate at lease one installation type in #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}: choose either helm_chart, helm_directory, or manifest_directory in cnf-testsuite.yml!".colorize(:red)
      exit 1
    end

    if !helm_chart.empty?
      {Helm::InstallMethod::HelmChart, helm_chart}
    elsif !helm_directory.empty?
      Log.info { "helm_directory not empty, using: #{full_helm_directory}" }
      {Helm::InstallMethod::HelmDirectory, full_helm_directory}
    elsif !manifest_directory.empty?
      Log.info { "manifest_directory not empty, using: #{full_manifest_directory}" }
      {Helm::InstallMethod::ManifestDirectory, full_manifest_directory}
    else
      puts "Error: Must populate at lease one installation type in #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}: choose either helm_chart, helm_directory, or manifest_directory.".colorize(:red)
      exit 1
    end
  end

  #TODO move to helm module
  def self.helm_template_header(helm_chart_or_directory : String, template_file="/tmp/temp_template.yml", airgapped=false)
    Log.info { "helm_template_header" }
    Log.info { "helm_template_header helm_chart_or_directory: #{helm_chart_or_directory}" }
    helm = BinarySingleton.helm
    # generate helm chart release name
    # use --dry-run to generate yml file
    Log.info { "airgapped mode: #{airgapped}" }
    if airgapped
      # todo make tar info work with a directory
      info = AirGap.tar_info_by_config_src(helm_chart_or_directory)
      Log.info { "airgapped mode info: #{info}" }
      helm_chart_or_directory = info[:tar_name]
    end
    Helm.install("--dry-run --generate-name #{helm_chart_or_directory} > #{template_file}")
    raw_template = File.read(template_file)
    Log.debug { "raw_template: #{raw_template}" }
    split_template = raw_template.split("---")
    template_header = split_template[0]
    parsed_template_header = YAML.parse(template_header)
    Log.debug { "parsed_template_header: #{parsed_template_header}" }
    parsed_template_header
  end

  #TODO move to helm module
  def self.helm_chart_template_release_name(helm_chart_or_directory : String, template_file="/tmp/temp_template.yml", airgapped=false)
    Log.info { "helm_chart_template_release_name" }
    Log.info { "airgapped mode: #{airgapped}" }
    Log.info { "helm_chart_template_release_name helm_chart_or_directory: #{helm_chart_or_directory}" }
    hth = helm_template_header(helm_chart_or_directory, template_file, airgapped)
    Log.info { "helm template (should not be a full path): #{hth}" }
    hth["NAME"]
  end


  def self.generate_and_set_release_name(config_yml_path, airgapped=false, generate_tar_mode=false)
    Log.info { "generate_and_set_release_name" }
    Log.info { "generate_and_set_release_name config_yml_path: #{config_yml_path}" }
    Log.info { "airgapped mode: #{airgapped}" }
    Log.info { "generate_tar_mode: #{generate_tar_mode}" }
    return if generate_tar_mode

    yml_file = CNFManager.ensure_cnf_testsuite_yml_path(config_yml_path)
    yml_path = CNFManager.ensure_cnf_testsuite_dir(config_yml_path)

    config = CNFManager.parsed_config_file(yml_file)

    predefined_release_name = optional_key_as_string(config, "release_name")
    Log.debug { "predefined_release_name: #{predefined_release_name}" }
    if predefined_release_name.empty?
      install_method = self.cnf_installation_method(config)
      Log.debug { "install_method: #{install_method}" }
      case install_method[0]
      when Helm::InstallMethod::HelmChart
        Log.info { "generate_and_set_release_name install method: #{install_method[0]} data: #{install_method[1]}" }
        Log.info { "generate_and_set_release_name helm_chart_or_directory: #{install_method[1]}" }
        release_name = helm_chart_template_release_name(install_method[1], airgapped: airgapped)
      when Helm::InstallMethod::HelmDirectory
        Log.info { "helm_directory install method: #{yml_path}/#{install_method[1]}" }
        # todo if in airgapped mode, use path for airgapped repositories
        # todo if in airgapped mode, get the release name
        # todo get the release name by looking through everything under /tmp/repositories
        Log.info { "generate_and_set_release_name helm_chart_or_directory: #{install_method[1]}" }
        release_name = helm_chart_template_release_name("#{install_method[1]}", airgapped: airgapped)
      when Helm::InstallMethod::ManifestDirectory
        Log.debug { "manifest_directory install method" }
        release_name = UUID.random.to_s
      else
        raise "Install method should be either helm_chart, helm_directory, or manifest_directory"
      end
      #set generated helm chart release name in yml file
      Log.debug { "generate_and_set_release_name: #{release_name}" }
      update_yml(yml_file, "release_name", release_name)
    end
  end


  # TODO move to sandbox module
  def self.cnf_destination_dir(config_file)
    Log.info { "cnf_destination_dir config_file: #{config_file}" }
    if path_has_yml?(config_file)
      yml = config_file
    else
      yml = config_file + "/cnf-testsuite.yml"
    end
    config = parsed_config_file(yml)
    Log.debug { "cnf_destination_dir parsed_config_file config: #{config}" }
    current_dir = FileUtils.pwd
    release_name = optional_key_as_string(config, "release_name").split(" ")[0]
    Log.info { "release_name: #{release_name}" }
    Log.info { "cnf destination dir: #{current_dir}/#{CNF_DIR}/#{release_name}" }
    "#{current_dir}/#{CNF_DIR}/#{release_name}"
  end

  def self.config_source_dir(config_file)
    if File.directory?(config_file)
      config_file
    else
      File.dirname(config_file)
    end
  end

  def self.helm_repo_add(helm_repo_name=nil, helm_repo_url=nil, args : Sam::Args=Sam::Args.new)
    Log.info { "helm_repo_add repo_name: #{helm_repo_name} repo_url: #{helm_repo_url} args: #{args.inspect}" }
    ret = false
    if helm_repo_name == nil || helm_repo_url == nil
      # config = get_parsed_cnf_testsuite_yml(args)
      # config = parsed_config_file(ensure_cnf_testsuite_yml_path(args.named["cnf-config"].as(String)))
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(args.named["cnf-config"].as(String)))
      Log.info { "helm path: #{BinarySingleton.helm}" }
      helm = BinarySingleton.helm
      # helm_repo_name = config.get("helm_repository.name").as_s?
      helm_repository = config.cnf_config[:helm_repository]
      helm_repo_name = "#{helm_repository && helm_repository["name"]}"
      helm_repo_url = "#{helm_repository && helm_repository["repo_url"]}"
      Log.info { "helm_repo_name: #{helm_repo_name}" }
      # helm_repo_url = config.get("helm_repository.repo_url").as_s?
      Log.info { "helm_repo_url: #{helm_repo_url}" }
    end
    if helm_repo_name && helm_repo_url
      ret = Helm.helm_repo_add(helm_repo_name, helm_repo_url)
    else
      ret = false
    end
    ret
  end

  def self.sample_setup_cli_args(args, noisy=true)
    Log.for("verbose").info { "sample_setup_cli_args" } if check_verbose(args)
    Log.for("verbose").debug { "args = #{args.inspect}" } if check_verbose(args)
    cnf_path = ""
    if args.named.keys.includes? "cnf-config"
      cnf_path = args.named["cnf-config"].as(String)
    elsif args.named.keys.includes? "cnf-path"
      cnf_path = args.named["cnf-path"].as(String)
    elsif noisy
      stdout_failure "Error: You must supply either cnf-config or cnf-path"
      exit 1
    else
      cnf_path = ""
    end
    if args.named.keys.includes? "wait_count"
      wait_count = args.named["wait_count"].to_i
    elsif args.named.keys.includes? "wait-count"
      wait_count = args.named["wait-count"].to_i
    else
      wait_count = 180
    end
    output_file = args.named["airgapped"].as(String) if args.named["airgapped"]?
    output_file = args.named["output-file"].as(String) if args.named["output-file"]?
    output_file = args.named["of"].as(String) if args.named["if"]?
    input_file = args.named["offline"].as(String) if args.named["offline"]?
    input_file = args.named["input-file"].as(String) if args.named["input-file"]?
    input_file = args.named["if"].as(String) if args.named["if"]?
    airgapped=false
    airgapped=true if args.raw.includes?("airgapped")

    cli_args = {config_file: cnf_path, wait_count: wait_count, verbose: check_verbose(args), output_file: output_file, input_file: input_file}
    Log.debug { "cli_args: #{cli_args}" }
    cli_args
  end

  # Create a unique directory for the cnf that is to be installed under ./cnfs
  # Only copy the cnf's cnf-testsuite.yml and it's helm_directory or manifest directory (if it exists)
  # Use manifest directory if helm directory empty
  def self.sandbox_setup(config, cli_args)
    Log.info { "sandbox_setup" }
    Log.info { "sandbox_setup config: #{config.cnf_config}" }
    verbose = cli_args[:verbose]
    config_file = config.cnf_config[:source_cnf_dir]
    release_name = config.cnf_config[:release_name]
    install_method = config.cnf_config[:install_method]
    helm_directory = config.cnf_config[:helm_directory]
    manifest_directory = config.cnf_config[:manifest_directory]
    helm_chart_path = config.cnf_config[:helm_chart_path]
    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)

    # Create a CNF sandbox dir
    FileUtils.mkdir_p(destination_cnf_dir)

    # Copy cnf-testsuite.yml file to the cnf sandbox dir
    copy_cnf_cmd = "cp -a #{ensure_cnf_testsuite_yml_path(config_file)} #{destination_cnf_dir}"
    Log.info { copy_cnf_cmd }
    status = Process.run(copy_cnf_cmd, shell: true)

    # todo manifest_or_helm_directory should either be the source helm/manifest files or the destination
    # directory that they will be copied to/generated into, but *not both*
    case install_method[0]
    when Helm::InstallMethod::ManifestDirectory
      Log.info { "preparing manifest_directory sandbox" }
      source_directory = config_source_dir(config_file) + "/" + manifest_directory
      src_path = Path[source_directory].expand.to_s
      Log.info { "cp -a #{src_path} #{destination_cnf_dir}" }

      begin
        FileUtils.cp_r(src_path, destination_cnf_dir)
      rescue File::AlreadyExistsError
        Log.info { "manifest sandbox dir already exists at #{destination_cnf_dir}/#{File.basename(src_path)}" }
      end
    when Helm::InstallMethod::HelmDirectory
      Log.info { "preparing helm_directory sandbox" }
      source_directory = config_source_dir(config_file) + "/" + helm_directory
      src_path = Path[source_directory].expand.to_s
      Log.info { "cp -a #{src_path} #{destination_cnf_dir}" }

      begin
        FileUtils.cp_r(src_path, destination_cnf_dir)
      rescue File::AlreadyExistsError
        Log.info { "helm sandbox dir already exists at #{destination_cnf_dir}/#{File.basename(src_path)}" }
      rescue File::NotFoundError
        Log.info { "helm directory not found at #{src_path}" }
        raise HelmDirectoryMissingError.new(src_path)
      end
    when Helm::InstallMethod::HelmChart
      Log.info { "preparing helm chart sandbox" }
      FileUtils.mkdir_p(Path[destination_cnf_dir].expand.to_s + "/exported_chart")
    end

    Log.for("verbose").debug {
      stdout = IO::Memory.new
      Process.run("ls -alR #{destination_cnf_dir}", shell: true, output: stdout, error: stdout)
      "Contents of destination_cnf_dir #{destination_cnf_dir}: \n#{stdout}"
    }
  end

  # Retrieve the helm chart source: only works with helm chart
  # installs (not helm directory or manifest directories)
  def self.export_published_chart(config, cli_args)
    Log.info { "exported_chart cli_args: #{cli_args}" }
    verbose = cli_args[:verbose]
    config_file = config.cnf_config[:source_cnf_dir]
    helm_directory = config.cnf_config[:helm_directory]
    helm_chart = config.cnf_config[:helm_chart]
    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)

    #TODO don't think we need to make this here
    FileUtils.mkdir_p("#{destination_cnf_dir}/#{helm_directory}")

    input_file = cli_args[:input_file]
    output_file = cli_args[:output_file]
    if input_file && !input_file.empty?
      # todo add generate and set tar as well
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file), airgapped: true) 
      tar_info = AirGap.tar_info_by_config_src(helm_chart)
      tgz_name = tar_info[:tar_name]
    elsif output_file && !output_file.empty?
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file), generate_tar_mode: true) 
      tgz_name = "#{Helm.chart_name(helm_chart)}-*.tgz"
    else
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file))
      tgz_name = "#{Helm.chart_name(helm_chart)}-*.tgz"
    end
    Log.info { "tgz_name: #{tgz_name}" }

    unless input_file && !input_file.empty?
      helm_info = Helm.pull(helm_chart) 
      puts "Helm pull error".colorize(:red)
      raise "Helm pull error" unless helm_info[:status].success? 
    end

    TarClient.untar(tgz_name,  "#{destination_cnf_dir}/exported_chart")

    Log.for("verbose").info { "mv #{destination_cnf_dir}/exported_chart/#{Helm.chart_name(helm_chart)}/* #{destination_cnf_dir}/exported_chart" } if verbose
    Log.for("verbose").debug {
      stdout = IO::Memory.new
      Process.run("ls -alR #{destination_cnf_dir}", shell: true, output: stdout, error: stdout)
      "Contents of destination_cnf_dir #{destination_cnf_dir} before move: \n#{stdout}"
    }

    FileUtils.mv(
      Dir.glob("#{destination_cnf_dir}/exported_chart/#{Helm.chart_name(helm_chart)}/*"),
      "#{destination_cnf_dir}/exported_chart"
    )

    Log.for("verbose").debug {
      stdout = IO::Memory.new
      Process.run("ls -alR #{destination_cnf_dir}", shell: true, output: stdout, error: stdout)
      "Contents of destination_cnf_dir #{destination_cnf_dir} after move: \n#{stdout}"
    }
  end

  #sample_setup({config_file: cnf_path, wait_count: wait_count})
  def self.sample_setup(cli_args)
    #TODO accept offline mode
    Log.info { "sample_setup cli_args: #{cli_args}" }
    config_file = cli_args[:config_file]
    wait_count = cli_args[:wait_count]
    verbose = cli_args[:verbose]
    input_file = cli_args[:input_file]
    output_file = cli_args[:output_file]
    if input_file && !input_file.empty?
      # todo add generate and set tar as well
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file), airgapped: true) 
    elsif output_file && !output_file.empty?
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file), generate_tar_mode: true) 
    else
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file))
    end
    Log.debug { "config in sample_setup: #{config.cnf_config}" }
    release_name = config.cnf_config[:release_name]
    install_method = config.cnf_config[:install_method]

    Log.for("verbose").info { "sample_setup" } if verbose
    Log.info { "config_file #{config_file}" }
    # config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file))

    release_name = config.cnf_config[:release_name]
    install_method = config.cnf_config[:install_method]
    helm_directory = config.cnf_config[:helm_directory]
    manifest_directory = config.cnf_config[:manifest_directory]
    git_clone_url = config.cnf_config[:git_clone_url]
    helm_repository = config.cnf_config[:helm_repository]
    helm_repo_name = "#{helm_repository && helm_repository["name"]}"
    helm_repo_url = "#{helm_repository && helm_repository["repo_url"]}"
    Log.info { "helm_repo_name: #{helm_repo_name}" }
    Log.info { "helm_repo_url: #{helm_repo_url}" }

    helm_chart_path = config.cnf_config[:helm_chart_path]
    Log.debug { "helm_directory: #{helm_directory}" }

    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)

    Log.for("verbose").info { "destination_cnf_dir: #{destination_cnf_dir}" } if verbose
    Log.debug { "mkdir_p destination_cnf_dir: #{destination_cnf_dir}" }
    FileUtils.mkdir_p(destination_cnf_dir)

    GitClient.clone("#{git_clone_url} #{destination_cnf_dir}/#{release_name}")  if git_clone_url.empty? == false

    begin
      sandbox_setup(config, cli_args)
    rescue e : HelmDirectoryMissingError
      stdout_warning "helm directory at #{e.helm_directory} is missing"
    end

    helm = BinarySingleton.helm
    Log.info { "helm path: #{BinarySingleton.helm}" }

    # This is to indicate if the release has already been setup.
    # Set it to false by default to indicate a new release is being setup
    fresh_install = true

    helm_install = {status: "", output: IO::Memory.new, error: IO::Memory.new}
    elapsed_time = Time.measure do
      case install_method[0]
      when Helm::InstallMethod::ManifestDirectory
        # todo airgap_manifest_directory << prepare a manifest directory for deployment into an airgapped environment, put in airgap module
        if input_file && !input_file.empty?
          yaml_template_files = Find.find("#{destination_cnf_dir}/#{manifest_directory}", 
                                               "*.yaml*", "100")
          yml_template_files = Find.find("#{destination_cnf_dir}/#{manifest_directory}", 
                                               "*.yml*", "100")
          template_files = yaml_template_files + yml_template_files
          Log.info { "(before kubectl apply) calling image_pull_policy on #{template_files}" }
          template_files.map{|x| AirGap.image_pull_policy(x)}
        end
        Log.for("verbose").info { "deploying by manifest file" } if verbose
        file_list = Helm::Manifest.manifest_file_list(install_method[1], silent=false)
        yml = Helm::Manifest.manifest_ymls_from_file_list(file_list)
        if input_file && !input_file.empty?
          image_pull(yml, "offline=true")
        else
          image_pull(yml, "offline=false")
        end
        KubectlClient::Apply.file("#{destination_cnf_dir}/#{manifest_directory}")
      when Helm::InstallMethod::HelmChart
        if input_file && !input_file.empty?
          tar_info = AirGap.tar_info_by_config_src(config.cnf_config[:helm_chart])
          # prepare a helm_chart tar file for deployment into an airgapped environment, put in airgap module
          TarClient.modify_tar!(tar_info[:tar_name]) do |directory| 
            template_files = Find.find(directory, "*.yaml*", "100")
            template_files.map{|x| AirGap.image_pull_policy(x)}
          end
          # if in airgapped mode, set helm_chart in config to be the tarball path
          helm_chart = tar_info[:tar_name]
        else
          helm_chart = config.cnf_config[:helm_chart]
        end
        if !helm_repo_name.empty? || !helm_repo_url.empty?
          Helm.helm_repo_add(helm_repo_name, helm_repo_url)
        end
        Log.for("verbose").info { "deploying with chart repository" } if verbose
        Helm.template(release_name, install_method[1], output_file="cnfs/temp_template.yml") 
        yml = Helm::Manifest.parse_manifest_as_ymls(template_file_name="cnfs/temp_template.yml")

        if input_file && !input_file.empty?
          image_pull(yml, "offline=true")
        else
          image_pull(yml, "offline=false")
        end
 
        begin
          helm_install = Helm.install("#{release_name} #{helm_chart}")
        rescue e : Helm::CannotReuseReleaseNameError
          stdout_warning "Release name #{release_name} has already been setup."
          # Mark that install is not fresh
          fresh_install = false
        end
        export_published_chart(config, cli_args)
      when Helm::InstallMethod::HelmDirectory
        Log.for("verbose").info { "deploying with helm directory" } if verbose
        # prepare a helm directory for deployment into an airgapped environment, put in airgap module
        if input_file && !input_file.empty?
          template_files = Dir.glob(["#{destination_cnf_dir}/#{helm_directory}/*.yaml*"])
          template_files.map{|x| AirGap.image_pull_policy(x)}
        end
        #TODO Add helm options into cnf-testsuite yml
        #e.g. helm install nsm --set insecure=true ./nsm/helm_chart
        Helm.template(release_name, install_method[1], output_file="cnfs/temp_template.yml") 
        yml = Helm::Manifest.parse_manifest_as_ymls(template_file_name="cnfs/temp_template.yml")
        
        if input_file && !input_file.empty?
          image_pull(yml, "offline=true")
        else
          image_pull(yml, "offline=false")
        end

        begin
          helm_install = Helm.install("#{release_name} #{destination_cnf_dir}/#{helm_directory}")
        rescue e : Helm::CannotReuseReleaseNameError
          stdout_warning "Release name #{release_name} has already been setup."
          # Mark that install is not fresh
          fresh_install = false
        end
      else
        raise "Deployment method not found"
      end

      resource_ymls = cnf_workload_resources(nil, config) do |resource|
        resource
      end
      resource_names = Helm.workload_resource_kind_names(resource_ymls)
      #TODO move to kubectlclient and make resource_install_and_wait_for_all function
      resource_names.each do | resource |
        case resource[:kind].as_s.downcase
        when "replicaset", "deployment", "statefulset", "pod", "daemonset"
          KubectlClient::Get.resource_wait_for_install(resource[:kind].as_s, resource[:name].as_s, wait_count)
        end
      end
    end

    Log.info { "elapsed_time.seconds: #{elapsed_time.seconds}" }
    helm_used = false
    if helm_install && helm_install[:error].to_s.size == 0 # && helm_pull.to_s.size > 0
      helm_used = true
      stdout_success "Successfully setup #{release_name}"
    end

    # Not required to write elapsed time configmap if the cnf already exists due to a previous Helm install
    return true if fresh_install == false

    # Immutable config maps are only supported in Kubernetes 1.19+
    immutable_configmap = true
    if version_less_than(KubectlClient.server_version, "1.19.0")
      immutable_configmap = false
    end

    #TODO if helm_install then set helm_deploy = true in template
    Log.info { "save config" }
    elapsed_time_template = Crinja.render(configmap_temp, { "helm_install" => helm_used, "release_name" => "cnf-testsuite-#{release_name}-startup-information", "elapsed_time" => "#{elapsed_time.seconds}", "immutable" => immutable_configmap})
    #TODO find a way to kubectlapply directly without a map
    Log.debug { "elapsed_time_template : #{elapsed_time_template}" }
    File.write("#{destination_cnf_dir}/configmap_test.yml", "#{elapsed_time_template}")
    # TODO if the config map exists on install, complain, delete then overwrite?
    KubectlClient::Delete.file("#{destination_cnf_dir}/configmap_test.yml")
    #TODO call kubectl apply on file
    KubectlClient::Apply.file("#{destination_cnf_dir}/configmap_test.yml")
    # TODO when uninstalling, remove config map
  end

def self.configmap_temp
  <<-TEMPLATE
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: '{{ release_name }}'
  {% if immutable %}
  immutable: true
  {% endif %}
  data:
    startup_time: '{{ elapsed_time }}'
    helm_used: '{{ helm_used }}'
  TEMPLATE
end


  def self.sample_cleanup(config_file, force=false, installed_from_manifest=false, verbose=true)
    Log.info { "sample_cleanup" }
    Log.info { "sample_cleanup installed_from_manifest: #{installed_from_manifest}" }
    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)
    Log.info { "destination_cnf_dir: #{destination_cnf_dir}" }
    config = parsed_config_file(ensure_cnf_testsuite_yml_path(config_file))

    Log.for("verbose").info { "cleanup config: #{config.inspect}" } if verbose
    KubectlClient::Delete.file("#{destination_cnf_dir}/configmap_test.yml")
    release_name = "#{config.get("release_name").as_s?}"
    manifest_directory = destination_cnf_dir + "/" + "#{config["manifest_directory"]? && config["manifest_directory"].as_s?}"
    Log.info { "manifest_directory: #{manifest_directory}" }

    Log.info { "helm path: #{BinarySingleton.helm}" }
    helm = BinarySingleton.helm
    dir_exists = File.directory?(destination_cnf_dir)
    ret = true
    Log.info { "destination_cnf_dir: #{destination_cnf_dir}" }
    # todo use install_from_config_src to determine installation method
    if dir_exists || force == true
      if installed_from_manifest
        ret = KubectlClient::Delete.file("#{manifest_directory}")
        # Log.for("verbose").info { kubectl_delete } if verbose
        # TODO put more safety around this
        FileUtils.rm_rf(destination_cnf_dir)
        if ret
          stdout_success "Successfully cleaned up #{manifest_directory} directory"
        end
      else
        helm_uninstall = Helm.uninstall(release_name.split(" ")[0])
        ret = helm_uninstall[:status].success?
        Log.for("verbose").info { helm_uninstall[:output].to_s } if verbose
        FileUtils.rm_rf(destination_cnf_dir)
        if ret
          stdout_success "Successfully cleaned up #{release_name.split(" ")[0]}"
        end
      end
    end
    ret
  end

  module CNFAirGap
    #  LOGGING.info ./cnf-testsuite cnf_setup cnf-config=example-cnfs/coredns/cnf-testsuite.yml airgapped output-file=./tmp/airgapped.tar.gz
    #  LOGGING.info ./cnf-testsuite cnf_setup cnf-config=example-cnfs/coredns/cnf-testsuite.yml output-file=./tmp/airgapped.tar.gz
    #  LOGGING.info ./cnf-testsuite cnf_setup cnf-config=example-cnfs/coredns/cnf-testsuite.yml airgapped=./tmp/airgapped.tar.gz
    def self.generate_cnf_setup(config_file : String, output_file, cli_args)
      Log.info { "generate_cnf_setup cnf_config_file: #{config_file}" }
      FileUtils.mkdir_p("#{TarClient::TAR_IMAGES_DIR}")
      # todo create a way to call setup code for directories (cnf manager code)
      config = CNFManager.parsed_config_file(config_file)
      sandbox_config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_testsuite_yml_path(config_file), airgapped: false, generate_tar_mode: true) 
      Log.info { "generate sandbox args: sandbox_config: #{sandbox_config}, cli_args: #{cli_args}" }
      CNFManager.sandbox_setup(sandbox_config, cli_args)
      install_method = CNFManager.cnf_installation_method(config)
      Log.info { "generate_cnf_setup images_from_config_src" }

      Log.info { "Download CRI Tools" }
      AirGap.download_cri_tools

      Log.info { "Add CRI Tools to Airgapped Tar: #{output_file}" }
      TarClient.append(output_file, TarClient::TAR_TMP_BASE, "bin/crictl-#{AirGap::CRI_VERSION}-linux-amd64.tar.gz")
      TarClient.append(output_file, TarClient::TAR_TMP_BASE, "bin/containerd-#{AirGap::CTR_VERSION}-linux-amd64.tar.gz")

      images = CNFManager::GenerateConfig.images_from_config_src(install_method[1], generate_tar_mode: true) 

      # todo function that takes sandbox containers and extracts images (config images)
      container_names = sandbox_config.cnf_config[:container_names]
      #todo get image name (org name and image name) from config src

      if container_names
        config_images = [] of NamedTuple(image_name: String, tag: String)
        container_names.map do |c|
          Log.info { "container_names c: #{c}" }
          # todo get image name for container name
          image = images.find{|x| x[:container_name]==c["name"]}
          if image
            config_images << {image_name: image[:image_name], tag: c["rolling_update_test_tag"]}
            config_images << {image_name: image[:image_name], tag: c["rolling_downgrade_test_tag"]}
            config_images << {image_name: image[:image_name], tag: c["rolling_version_change_test_tag"]}
            config_images << {image_name: image[:image_name], tag: c["rollback_from_tag"]}
          end
        end
      else
        config_images = [] of NamedTuple(image_name: String, tag: String)
      end
      Log.info { "config_images: #{config_images}" }

      # todo function that accepts image names and tars them
      images = images + config_images
      images.map  do |i|
        input_file = "#{TarClient::TAR_IMAGES_DIR}/#{i[:image_name].split("/")[-1]}_#{i[:tag]}.tar"
        Log.info { "input_file: #{input_file}" }
        image = "#{i[:image_name]}:#{i[:tag]}"
        DockerClient.pull(image)
        DockerClient.save(image, input_file)
        TarClient.append(output_file, "/tmp", "images/" + input_file.split("/")[-1])
        Log.info { "#{output_file} in generate_cnf_setup complete" }
      end
      # todo hardcode install method for helm charts until helm directories / manifest 
      #  directories are supported
      case install_method[0]
      when Helm::InstallMethod::HelmChart
        Log.debug { "helm_chart : #{install_method[1]}" }
        AirGap.tar_helm_repo(install_method[1], output_file)
        Log.info { "generate_cnf_setup tar_helm_repo complete" }
        # when Helm::InstallMethod::ManifestDirectory
        #   LOGGING.debug "manifest_directory : #{install_method[1]}"
        #   template_files = Find.find(directory, "*.yaml*", "100")
        #   template_files.map{|x| AirGap.image_pull_policy(x)}
      end
    end

    #./cnf-testsuite airgapped -o ~/airgapped.tar.gz
    #./cnf-testsuite offline -o ~/airgapped.tar.gz
    #./cnf-testsuite offline -o ~/mydir/airgapped.tar.gz
    def self.generate(output_file : String = "./airgapped.tar.gz")
      Log.info { "cnf_manager generate" }
      FileUtils.rm_rf(output_file)
      FileUtils.mkdir_p("#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}")
      FileUtils.mkdir_p("#{AirGap::TAR_BINARY_DIR}")

      # todo put all of these setup elements into a configuration file.

      [{input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/kubectl.tar", 
        image: "bitnami/kubectl:latest"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/chaos-mesh.tar", 
       image: "pingcap/chaos-mesh:v1.2.1"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/chaos-daemon.tar", 
       image: "pingcap/chaos-daemon:v1.2.1"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/chaos-dashboard.tar", 
       image: "pingcap/chaos-dashboard:v1.2.1"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/chaos-kernel.tar", 
       image: "pingcap/chaos-kernel:v1.2.1"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/pingcap-coredns.tar", 
       image: "pingcap/coredns:v0.2.0"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/sonobuoy.tar", 
       image: "docker.io/sonobuoy/sonobuoy:v0.19.0"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/sonobuoy-logs.tar", 
       image: "docker.io/sonobuoy/systemd-logs:v0.3"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/litmus-operator.tar", 
       image: "litmuschaos/chaos-operator:#{LitmusManager::Version}"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/litmus-runner.tar", 
       image: "litmuschaos/chaos-runner:#{LitmusManager::Version}"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/go-runner.tar", 
       image: "litmuschaos/go-runner:#{LitmusManager::Version}"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/gatekeeper.tar", 
       image: "openpolicyagent/gatekeeper:v3.6.0"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/gatekeeper-crds.tar", 
       image: "openpolicyagent/gatekeeper-crds:v3.6.0"},
      {input_file: "#{AirGap::TAR_BOOTSTRAP_IMAGES_DIR}/prometheus.tar", 
       image: "prom/prometheus:v2.18.1"}].map do |x|
        DockerClient.pull(x[:image])
        DockerClient.save(x[:image], x[:input_file])
        TarClient.append(output_file, TarClient::TAR_TMP_BASE, "bootstrap_images/" + x[:input_file].split("/")[-1])
      end
      # todo keep crictl and containerd tar files, move to the rest to cnf-test-suite specific bootstrap
      AirGap.tar_manifest("https://litmuschaos.github.io/litmus/litmus-operator-v#{LitmusManager::Version}.yaml", output_file)
      AirGap.tar_manifest("https://raw.githubusercontent.com/litmuschaos/chaos-operator/master/deploy/chaos_crds.yaml", output_file)
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-network-latency/experiment.yaml", output_file, prefix: "lat-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-network-latency/rbac.yaml", output_file, prefix: "lat-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-network-corruption/experiment.yaml", output_file, prefix: "corr-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-network-corruption/rbac.yaml", output_file, prefix:  "corr-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-network-duplication/experiment.yaml", output_file, prefix: "dup-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-network-duplication/rbac.yaml", output_file, prefix:  "dup-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-delete/experiment.yaml", output_file, prefix: "pod-delete-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-delete/rbac.yaml", output_file, prefix:  "pod-delete-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-memory-hog/experiment.yaml", output_file, prefix: "pod-memory-hog-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-memory-hog/rbac.yaml", output_file, prefix:  "pod-memory-hog-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-io-stress/experiment.yaml", output_file, prefix: "pod-io-stress-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/pod-io-stress/rbac.yaml", output_file, prefix:  "pod-io-stress-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/disk-fill/experiment.yaml", output_file, prefix:  "disk-fill-")
      AirGap.tar_manifest("https://hub.litmuschaos.io/api/chaos/#{LitmusManager::Version}?file=charts/generic/disk-fill/rbac.yaml", output_file, prefix:  "disk-fill-")
      url = "https://github.com/vmware-tanzu/sonobuoy/releases/download/v#{SONOBUOY_K8S_VERSION}/sonobuoy_#{SONOBUOY_K8S_VERSION}_#{SONOBUOY_OS}_amd64.tar.gz"
      TarClient.tar_file_by_url(url, output_file, "sonobuoy.tar.gz")
      url = "https://github.com/armosec/kubescape/releases/download/v#{KUBESCAPE_VERSION}/kubescape-ubuntu-latest"
      TarClient.tar_file_by_url(url, output_file, "kubescape-ubuntu-latest")
      download_path = "download/" 
      FileUtils.rm_rf("#{TarClient::TAR_TMP_BASE}/#{download_path}")
      FileUtils.mkdir_p("#{TarClient::TAR_TMP_BASE}/" + download_path)
      `./tools/kubescape/kubescape download framework nsa --output #{TarClient::TAR_DOWNLOAD_DIR}/nsa.json`
      TarClient.append(output_file, TarClient::TAR_TMP_BASE, "#{download_path}nsa.json")
      Helm.helm_repo_add("chaos-mesh", "https://charts.chaos-mesh.org")
      # todo create helm chart configuration yaml that includes all chart elements for specs
      AirGap.tar_helm_repo("chaos-mesh/chaos-mesh --version 0.5.1", output_file)
      Helm.helm_repo_add("gatekeeper","https://open-policy-agent.github.io/gatekeeper/charts")
      AirGap.tar_helm_repo("gatekeeper/gatekeeper --version 3.6.0", output_file)
      AirGap.generate(output_file, append=true)


    end
  end

  class HelmDirectoryMissingError < Exception
    property helm_directory : String = ""

    def initialize(helm_directory : String)
      self.helm_directory = helm_directory
    end
  end

end
