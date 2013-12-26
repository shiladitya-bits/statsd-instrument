require 'socket'
require 'benchmark'

class << Benchmark
  def ms
    1000 * realtime { yield }
  end
end


module StatsD
  class << self
    attr_accessor :host, :port, :mode, :logger, :enabled, :default_sample_rate,
                  :prefix, :implementation
  end
  self.enabled = true
  self.default_sample_rate = 1.0
  self.implementation = :statsd

  # StatsD.server = 'localhost:1234'
  def self.server=(conn)
    self.host, port = conn.split(':')
    self.port = port.to_i
    invalidate_socket
  end

  def self.host=(host)
    @host = host
    invalidate_socket
  end

  def self.port=(port)
    @port = port
    invalidate_socket
  end

  module Instrument
    def statsd_measure(method, name, sample_rate = StatsD.default_sample_rate)
      add_to_method(method, name, :measure) do |old_method, new_method, metric_name, *args|
        define_method(new_method) do |*args, &block|
          StatsD.measure(metric_name.respond_to?(:call) ? metric_name.call(self, args) : metric_name, nil, sample_rate) { send(old_method, *args, &block) }
        end
      end
    end

    def statsd_count_success(method, name, sample_rate = StatsD.default_sample_rate)
      add_to_method(method, name, :count_success) do |old_method, new_method, metric_name|
        define_method(new_method) do |*args, &block|
          begin
            truthiness = result = send(old_method, *args, &block)
          rescue
            truthiness = false
            raise
          else
            truthiness = (yield(result) rescue false) if block_given?
            result
          ensure
            result = truthiness == false ? 'failure' : 'success'
            key = metric_name.respond_to?(:call) ? metric_name.call(self, args) : metric_name

            StatsD.increment("#{key}.#{result}", sample_rate)
          end
        end
      end
    end

    def statsd_count_if(method, name, sample_rate = StatsD.default_sample_rate)
      add_to_method(method, name, :count_if) do |old_method, new_method, metric_name|
        define_method(new_method) do |*args, &block|
          begin
            truthiness = result = send(old_method, *args, &block)
          rescue
            truthiness = false
            raise
          else
            truthiness = (yield(result) rescue false) if block_given?
            result
          ensure
            StatsD.increment(metric_name.respond_to?(:call) ? metric_name.call(self, args) : metric_name, sample_rate) if truthiness
          end
        end
      end
    end

    def statsd_count(method, name, sample_rate = StatsD.default_sample_rate)
      add_to_method(method, name, :count) do |old_method, new_method, metric_name|
        define_method(new_method) do |*args, &block|
          StatsD.increment(metric_name.respond_to?(:call) ? metric_name.call(self, args) : metric_name, sample_rate)
          send(old_method, *args, &block)
        end
      end
    end

    private
    def add_to_method(method, name, action, &block)
      metric_name = name

      method_name_without_statsd = :"#{method}_for_#{action}_on_#{self.name}_without_#{name}"
      # raw_ssl_request_for_measure_on_FedEx_without_ActiveMerchant.Shipping.#{self.class.name}.ssl_request

      method_name_with_statsd = :"#{method}_for_#{action}_on_#{self.name}_with_#{name}"
      # raw_ssl_request_for_measure_on_FedEx_with_ActiveMerchant.Shipping.#{self.class.name}.ssl_request

      raise ArgumentError, "already instrumented #{method} for #{self.name}" if method_defined? method_name_without_statsd
      raise ArgumentError, "could not find method #{method} for #{self.name}" unless method_defined?(method) || private_method_defined?(method)

      alias_method method_name_without_statsd, method
      yield method_name_without_statsd, method_name_with_statsd, metric_name
      alias_method method, method_name_with_statsd
    end
  end

  # glork:320|ms
  def self.measure(key, milli = nil, sample_rate = default_sample_rate, tags = nil)
    result = nil
    ms = milli || Benchmark.ms do
      result = yield
    end

    write(key, ms, :ms, sample_rate, tags)
    result
  end

  # gorets:1|c
  def self.increment(key, delta = 1, sample_rate = default_sample_rate, tags = nil)
    write(key, delta, :incr, sample_rate, tags)
  end

  # gaugor:333|g
  # guagor:1234|kv|@1339864935 (statsite)
  def self.gauge(key, value, sample_rate_or_epoch = default_sample_rate, tags = nil)
    write(key, value, :g, sample_rate_or_epoch, tags)
  end

  # histogram:123.45|h
  def self.histogram(key, value, sample_rate_or_epoch = default_sample_rate, tags = nil)
    write(key, value, :h, sample_rate_or_epoch, tags)
  end  

  private

  def self.invalidate_socket
    @socket = nil
  end

  def self.socket
    if @socket.nil?
      @socket = UDPSocket.new
      @socket.connect(host, port)
    end
    @socket
  end

  def self.write(k,v,op, sample_rate = default_sample_rate, tags = nil)
    return unless enabled
    return if sample_rate < 1 && rand > sample_rate

    k =  k.gsub('::', '.')

    command = "#{self.prefix + '.' if self.prefix}#{k}:#{v}"
    case op
    when :incr
      command << '|c'
    when :ms
      command << '|ms'
    when :g
      command << (self.implementation == :statsite ? '|kv' : '|g')
    when :h
      raise NotImplemented, "Histograms only supported on DataDog implementation." unless self.implementation == :datadog
      command << '|h'
    end

    command << "|@#{sample_rate}" if sample_rate < 1 || (self.implementation == :statsite && sample_rate > 1)
    if tags
      raise ArgumentError, "Tags are only supported on Datadog" unless self.implementation == :datadog
      raise ArgumentError, "Tags not prperly formatted." unless tags.all? { |t| t =~ /([\w-]+:)?[\w-]+/ }
      command << "|##{tags.join(',')}"
    end

    command << "\n" if self.implementation == :statsite

    if mode.to_s == 'production'
      socket_wrapper { socket.send(command, 0) }
    else
      logger.info "[StatsD] #{command}"
    end
  end

  def self.socket_wrapper(options = {})
    yield
  rescue SocketError, IOError, SystemCallError => e
    logger.error e
  end
end

