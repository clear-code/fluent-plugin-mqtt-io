require 'mqtt'
module Fluent::Plugin
  module MqttProxy
    MQTT_PORT = 1883

    def self.included(base)
      base.helpers :timer, :thread

      base.desc 'The address to connect to.'
      base.config_param :host, :string, default: '127.0.0.1'
      base.desc 'The port to connect to.'
      base.config_param :port, :integer, default: MQTT_PORT
      base.desc 'Client ID of MQTT Connection'
      base.config_param :client_id, :string, default: nil
      base.desc 'Specify clean session value.'
      base.config_param :clean_session, :bool, default: true
      base.desc 'Specify keep alive interval.'
      base.config_param :keep_alive, :integer, default: 15
      base.desc 'Specify initial connection retry interval.'
      base.config_param :initial_interval, :integer, default: 1
      base.desc 'Specify increasing ratio of connection retry interval.'
      base.config_param :retry_inc_ratio, :integer, default: 2
      base.desc 'Specify the maximum connection retry interval.'
      base.config_param :max_retry_interval, :integer, default: 300
      base.desc 'Specify threshold of retry frequency as number of retries per minutes. Frequency is monitored per retry.'
      base.config_param :max_retry_freq, :integer, default: 10

      base.config_section :security, required: false, multi: false do
        ### User based authentication
        desc 'The username for authentication'
        config_param :username, :string, default: nil
        desc 'The password for authentication'
        config_param :password, :string, default: nil
        desc 'Use TLS or not.'
        config_param :use_tls, :bool, default: nil
        config_section :tls, required: false, multi: false do
          desc 'Specify TLS ca file.'
          config_param :ca_file, :string, default: nil
          desc 'Specify TLS key file.'
          config_param :key_file, :string, default: nil
          desc 'Specify TLS cert file.'
          config_param :cert_file, :string, default: nil
        end
      end
    end

    class MqttError < StandardError; end

    class ExceedRetryFrequencyThresholdException < StandardError; end

    def current_plugin_name
      # should be implemented
    end

    def start_proxy
      @proxy_thread = thread_create("#{current_plugin_name}_proxy".to_sym, &method(:proxy))
    end

    def proxy
      log.debug "start mqtt proxy for #{current_plugin_name}"
      log.debug "start to connect mqtt broker #{@host}:#{@port}"
      opts = {
        host: @host,
        port: @port,
        client_id: @client_id,
        clean_session: @clean_session,
        keep_alive: @keep_alive
      }
      opts[:username] = @security.username if @security.to_h.has_key?(:username)
      opts[:password] = @security.password if @security.to_h.has_key?(:password)
      if @security.to_h.has_key?(:use_tls) && @security.use_tls
        opts[:ssl] = @security.use_tls
        opts[:ca_file] = @security.tls.ca_file
        opts[:cert_file] = @security.tls.cert_file
        opts[:key_file] = @security.tls.key_file
      end

      init_retry_interval
      @retry_sequence = []
      @client = MQTT::Client.new(opts)
      # required to rescue MQTT::ProtocolException
      @monitor_thread = thread_create("#{current_plugin_name}_monitor".to_sym, &method(:connect))
    end

    def shutdown_proxy
      @client.disconnect
    end

    def init_retry_interval
      @retry_interval = @initial_interval
    end

    def increment_retry_interval
      return @max_retry_interval if @retry_interval >= @max_retry_interval
      @retry_interval = @retry_interval * @retry_inc_ratio
    end

    def update_retry_sequence(e) 
      @retry_sequence << {time: Time.now, error: "#{e.class}: #{e.message}"}
      # delete old retry records
      while @retry_sequence[0][:time] < Time.now - 60
        @retry_sequence.shift
      end 
    end

    def check_retry_frequency
      return if @retry_sequence.size <= 1
      if @retry_sequence.size > @max_retry_freq
        log.error "Retry frequency threshold is exceeded: #{@retry_sequence}"
        raise ExceedRetryFrequencyThresholdException
      end
    end

    def retry_connect(e, message)
      log.error "#{message},#{e.class},#{e.message}"
      log.error "Retry in #{@retry_interval} sec"
      update_retry_sequence(e)
      check_retry_frequency
      disconnect
      sleep @retry_interval
      increment_retry_interval
      connect
      # never reach here
    end

    def disconnect
      # should be implemented
    end

    def terminate
    end

    def rescue_disconnection
      # Errors cannot be caught by fluentd core must be caught here.
      # Since fluentd core retries write method for buffered output 
      # when it caught Errors during the previous write,
      # caughtable Error, e.g. MqttError, should be raised here.
      begin
        yield
      rescue MQTT::ProtocolException => e
        retry_connect(e, "Protocol error occurs in #{current_plugin_name}.")
      rescue Timeout::Error => e
        retry_connect(e, "Timeout error occurs in #{current_plugin_name}.")
      rescue SystemCallError => e
        retry_connect(e, "System call error occurs in #{current_plugin_name}.")
      rescue StandardError=> e
        retry_connect(e, "The other error occurs in #{current_plugin_name}.")
      rescue MQTT::NotConnectedException=> e
        # Since MQTT::NotConnectedException is raised only on publish,
        # connection error should be catched before this error.
        # So, reconnection process is omitted for this Exception
        # to prevent waistful increment of retry interval.
        #log.error "MQTT not connected exception occurs.,#{e.class},#{e.message}"
        #retry_connect(e, "MQTT not connected exception occurs.")
        #raise MqttError, "MQTT not connected exception occurs in #{current_plugin_name}."
      end
    end

    def after_connection
      # should be implemented
      # returns thread instance for monitor thread to wait
      # for Exception raised by MQTT I/O
    end

    def connect
      rescue_disconnection do
        @client.connect
        log.debug "connected to mqtt broker #{@host}:#{@port} for #{current_plugin_name}"
        init_retry_interval
        thread = after_connection
        thread.join
      end
    end
  end
end
