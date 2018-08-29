# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'open3'
require 'shellwords'
require_relative 'project'
require_relative 'logging/logging_support'

#
# Ruby wrapper for oc tools
#
module RbShift
  # Client starting point
  class Client
    include Logging::LoggingSupport

    attr_reader :token, :url

    class InvalidAuthorizationError < StandardError;
    end
    class InvalidCommandError < StandardError;
    end

    def initialize(url, bearer_token: nil, username: nil, password: nil, verify_ssl: true)
      raise InvalidAuthorizationError if bearer_token.nil? && (username.nil? || password.nil?)

      @token      = bearer_token || Client.get_token(url, username, password)
      @url        = url
      @kubernetes = RestClient::Resource.new "#{url}/api/v1",
                                             verify_ssl: verify_ssl,
                                             headers:    { Authorization: "Bearer #{@token}" }
      @openshift  = RestClient::Resource.new "#{url}/oapi/v1",
                                             verify_ssl: verify_ssl,
                                             headers:    { Authorization: "Bearer #{@token}" }
      @root       = RestClient::Resource.new url,
                                             verify_ssl: verify_ssl,
                                             headers:    { Authorization: "Bearer #{@token}" }

      log.info("RbShift client created for #{@url}")
    end

    # @api public
    # Retrieves resources from OpenShift or kubernetes API
    #
    # @param [Class] resource Resource class
    # @param [List] opts Options
    # @option [String] namespace
    # @option [String] name Name of the resource
    # @return [List] List of resources
    def get(resource, **opts)
      request = +''
      request << "namespaces/#{opts[:namespace]}/" if opts[:namespace]
      request << resource.to_s
      request << "/#{opts[:name]}" if opts[:name]
      client = client resource
      log.debug "Getting #{resource} from #{client}..."
      make_get_request(client, request)
    end

    def read_link(link)
      response = make_request(@root[link])
      process_response JSON.parse(response, symbolize_names: true)
    end

    def process_response(response)
      response = response.keys.include?(:items) ? response[:items] : response
      log.debug(" -> Response #{response}") if ENV['RB_SHIFT_LOG_RESPONSES']
      response
    end

    def create_project(name, **opts)
      log.info "Creating project #{name}"
      execute "new-project #{name}", **opts
      project = nil
      project = projects(true)[name] until project
      project
    end

    def projects(update = false)
      @_projects = load_projects if update || !@_projects
      @_projects
    end

    def execute(command, **opts)
      log.debug("[EXEC] Executing command #{command} with opts: #{opts}")
      oc_cmd = oc_command(command, **opts)
      log.debug oc_cmd
      stdout, stderr, stat = Open3.capture3(oc_cmd)
      unless stderr.empty? && stat.success?
        log.error oc_command(command, exclude_token: true, **opts)
        log.error "Command failed with status #{stat.exitstatus} -->"
        log.debug "Standard Output: #{stdout}"
        log.error "Error Output: #{stderr}"
        raise InvalidCommandError, "ERROR: #{stdout} #{stderr}"
      end
    end

    def wait_project_deletion(project_name, timeout = 1)
      sleep timeout while get('projects').find { |v| v[:metadata][:name] == project_name }
      projects true
    end

    # rubocop:disable Metrics/LineLength
    def self.get_token(ose_server, username, password)
      `oc login #{ose_server} --username=#{username} --password=#{password} --insecure-skip-tls-verify`
      `oc whoami --show-token`.strip
    end

    # rubocop:enable Metrics/LineLength

    private

    def make_get_request(client, request_path)
      request = client[request_path]
      response = make_request request
      process_response JSON.parse(response, symbolize_names: true)
    end

    def oc_command(command, exclude_token: false, **opts)
      token = exclude_token ? '***' : @token
      "oc --server=\"#{@url}\" --token=\"#{token}\" #{command} #{unfold_opts opts}"
    end

    def client(resource)
      return @kubernetes if kube_entities.include?(resource)
      return @openshift if os_entities.include?(resource)
      raise "Resource '#{resource}' not supported!"
    end

    def load_projects
      items = get('projects')
      items.each_with_object({}) do |item, hash|
        resource            = Project.new(item[:metadata][:name], self)
        hash[resource.name] = resource
      end
    end

    def make_request(client)
      log.debug("[REQUEST] Making Request #{client.url}")
      client.get
    rescue RestClient::ExceptionWithResponse => ex
      log.error("[RESPONSE] Error response: #{ex.response}")
      ex.response
    end

    def load_entities(client)
      response = make_request client
      JSON
        .parse(response)['resources']
        .reject { |resource| resource['name'].include?('/') }
        .map { |resource| resource['name'] }
        .uniq
    end

    # rubocop:disable Naming/MemoizedInstanceVariableName
    def kube_entities
      @_kube_entities ||= load_entities(@kubernetes)
    end

    def os_entities
      @_os_entities ||= load_entities(@openshift)
    end

    # rubocop:enable Naming/MemoizedInstanceVariableName

    def unfold_opts(opts)
      opts.map do |k, v|
        case v
        when Array
          v.map { |l| "--#{k}=#{l.to_s.shellescape}" }.join(' ')
        when Hash
          v.map { |m, n| "--#{k}=#{m}=#{n.to_s.shellescape}" }.join(' ')
        when NilClass
          next
        else
          "--#{k}=#{v.to_s.shellescape}"
        end
      end.join(' ')
    end
  end
end
