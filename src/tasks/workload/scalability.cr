# coding: utf-8
require "sam"
require "file_utils"
require "colorize"
require "totem"
require "../utils/utils.cr"

desc "The CNF test suite checks to see if CNFs support horizontal scaling (across multiple machines) and vertical scaling (between sizes of machines) by using the native K8s kubectl"
task "scalability", ["increase_decrease_capacity"] do |t, args|
  VERBOSE_LOGGING.info "scalability" if check_verbose(args)
  VERBOSE_LOGGING.debug "scaling args.raw: #{args.raw}" if check_verbose(args)
  VERBOSE_LOGGING.debug "scaling args.named: #{args.named}" if check_verbose(args)
  # t.invoke("increase_decrease_capacity", args)
  stdout_score("scalability")
end

desc "Test increasing/decreasing capacity"
task "increase_decrease_capacity", ["increase_capacity", "decrease_capacity"] do |t, args|
  VERBOSE_LOGGING.info "increase_decrease_capacity" if check_verbose(args)
end


def increase_decrease_capacity_failure_msg(target_replicas, emoji)
<<-TEMPLATE
✖️  FAILURE: Replicas did not reach #{target_replicas} #{emoji}

Replica failure can be due to insufficent permissions, image pull errors and other issues.
Learn more on remediation by viewing our USAGE.md doc at https://bit.ly/capacity_remedy

TEMPLATE
end

desc "Test increasing capacity by setting replicas to 1 and then increasing to 3"
task "increase_capacity" do |_, args|
  CNFManager::Task.task_runner(args) do |args, config|
    VERBOSE_LOGGING.info "increase_capacity" if check_verbose(args)
    emoji_increase_capacity="📦📈"

    target_replicas = "3"
    base_replicas = "1"
    # TODO scale replicatsets separately
    # https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/#scaling-a-replicaset
    # resource["kind"].as_s.downcase == "replicaset"
    task_response = CNFManager.cnf_workload_resources(args, config) do | resource|
      if resource["kind"].as_s.downcase == "deployment" ||
          resource["kind"].as_s.downcase == "statefulset"
        final_count = change_capacity(base_replicas, target_replicas, args, config, resource)
        target_replicas == final_count
      else
        true
      end
    end
    # if target_replicas == final_count 
    if task_response.none?(false) 
      upsert_passed_task("increase_capacity", "✔️  PASSED: Replicas increased to #{target_replicas} #{emoji_increase_capacity}")
    else
      upsert_failed_task("increase_capacity", increase_decrease_capacity_failure_msg(target_replicas, emoji_increase_capacity))
    end
  end
end

desc "Test decrease capacity by setting replicas to 3 and then decreasing to 1"
task "decrease_capacity" do |_, args|
  CNFManager::Task.task_runner(args) do |args, config|
    VERBOSE_LOGGING.info "decrease_capacity" if check_verbose(args)
    target_replicas = "1"
    base_replicas = "3"
    task_response = CNFManager.cnf_workload_resources(args, config) do | resource|
      # TODO scale replicatsets separately
      # https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/#scaling-a-replicaset
      # resource["kind"].as_s.downcase == "replicaset"
      if resource["kind"].as_s.downcase == "deployment" ||
          resource["kind"].as_s.downcase == "statefulset"
        final_count = change_capacity(base_replicas, target_replicas, args, config, resource)
        target_replicas == final_count
      else
        true
      end
    end
    emoji_decrease_capacity="📦📉"

    # if target_replicas == final_count 
    if task_response.none?(false) 
      upsert_passed_task("decrease_capacity", "✔️  PASSED: Replicas decreased to #{target_replicas} #{emoji_decrease_capacity}")
    else
      upsert_failed_task("decrease_capacity", increase_decrease_capacity_failure_msg(target_replicas, emoji_decrease_capacity))
    end
  end
end

def change_capacity(base_replicas, target_replica_count, args, config, resource = {kind: "", 
                                                                                   metadata: {name: ""}})
  VERBOSE_LOGGING.info "change_capacity" if check_verbose(args)
  VERBOSE_LOGGING.debug "increase_capacity args.raw: #{args.raw}" if check_verbose(args)
  VERBOSE_LOGGING.debug "increase_capacity args.named: #{args.named}" if check_verbose(args)
  VERBOSE_LOGGING.info "base replicas: #{base_replicas}" if check_verbose(args)
  LOGGING.debug "resource: #{resource}"

  initialization_time = base_replicas.to_i * 10
  VERBOSE_LOGGING.info "resource: #{resource["metadata"]["name"]}" if check_verbose(args)

  scale_cmd = ""

  case resource["kind"].as_s.downcase
  when "deployment"
    scale_cmd = "#{resource["kind"]}.v1.apps/#{resource["metadata"]["name"]} --replicas=#{base_replicas}"
  when "statefulset"
    scale_cmd = "statefulsets #{resource["metadata"]["name"]} --replicas=#{base_replicas}"
  else #TODO what else can be scaled?
    scale_cmd = "#{resource["kind"]}.v1.apps/#{resource["metadata"]["name"]} --replicas=#{base_replicas}"
  end
  KubectlClient::Scale.command(scale_cmd)

  initialized_count = wait_for_scaling(resource, base_replicas, args)

  if check_verbose(args)
    if initialized_count != base_replicas
      VERBOSE_LOGGING.info "#{resource["kind"]} initialized to #{initialized_count} and could not be set to #{base_replicas}" 
    else
      VERBOSE_LOGGING.info "#{resource["kind"]} initialized to #{initialized_count}"
    end
  end

  case resource["kind"].as_s.downcase
  when "deployment"
    scale_cmd = "#{resource["kind"]}.v1.apps/#{resource["metadata"]["name"]} --replicas=#{target_replica_count}"
  when "statefulset"
    scale_cmd = "statefulsets #{resource["metadata"]["name"]} --replicas=#{target_replica_count}"
  else #TODO what else can be scaled?
    scale_cmd = "#{resource["kind"]}.v1.apps/#{resource["metadata"]["name"]} --replicas=#{target_replica_count}"
  end
  KubectlClient::Scale.command(scale_cmd)

  current_replicas = wait_for_scaling(resource, target_replica_count, args)
  current_replicas
end

def wait_for_scaling(resource, target_replica_count, args)
  VERBOSE_LOGGING.info "target_replica_count: #{target_replica_count}" if check_verbose(args)
  if args.named.keys.includes? "wait_count"
    wait_count_value = args.named["wait_count"]
  else
    wait_count_value = "30"
  end
  wait_count = wait_count_value.to_i
  second_count = 0
  current_replicas = "0"
  replicas_cmd = "kubectl get #{resource["kind"]} #{resource["metadata"]["name"]} -o=jsonpath='{.status.readyReplicas}'"
  Process.run(
    replicas_cmd,
    shell: true,
    output: replicas_stdout = IO::Memory.new,
    error: replicas_stderr = IO::Memory.new
  )
  previous_replicas = replicas_stdout.to_s
  until current_replicas == target_replica_count || second_count > wait_count
    Log.for("verbose").debug { "secound_count: #{second_count} wait_count: #{wait_count}" } if check_verbose(args)
    Log.for("verbose").info { "current_replicas before get #{resource["kind"]}: #{current_replicas}" } if check_verbose(args)
    sleep 1
    Log.for("verbose").debug { "$KUBECONFIG = #{ENV.fetch("KUBECONFIG", nil)}" } if check_verbose(args)

    Process.run(
      replicas_cmd,
      shell: true,
      output: replicas_stdout = IO::Memory.new,
      error: replicas_stderr = IO::Memory.new
    )
    current_replicas = replicas_stdout.to_s

    Log.for("verbose").info { "current_replicas after get #{resource["kind"]}: #{current_replicas.inspect}" } if check_verbose(args)

    if current_replicas.empty?
      current_replicas = "0"
      previous_replicas = "0"
    end

    if current_replicas.to_i != previous_replicas.to_i
      second_count = 0
      previous_replicas = current_replicas
    end
    second_count = second_count + 1 
    Log.for("verbose").info { "previous_replicas: #{previous_replicas}" } if check_verbose(args)
    Log.for("verbose").info { "current_replicas: #{current_replicas}" } if check_verbose(args)
  end
  current_replicas
end 

