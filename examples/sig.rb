#!/usr/bin/env ruby
=begin
# sig.rb

ServerLog IRC Gateway

# Usage

 * Connect.
 * Join a channel (you can name it as you like)
 * Set topic "filename regexp"
 * You will see the log at the channel only matching the regexp.

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

require "rubygems"
require "net/irc"
require "logger"
require "pathname"
require "yaml"

class ServerLogIrcGateway < Net::IRC::Server::Session
	def server_name
		"serverlog"
	end

	def server_version
		"0.0.0"
	end


	def initialize(*args)
		super
		@channels = {}
		@config   = Pathname.new(ENV["HOME"]) + ".sig"
	end

	def on_disconnected
		@channels.each do |chan, info|
			begin
				info[:observer].kill if info[:observer]
			rescue
			end
		end
	end

	def on_user(m)
		super
		@real, *@opts = @real.split(/\s+/)
		@opts ||= []
	end

	def on_join(m)
		channels = m.params.first.split(/,/)
		channels.each do |channel|
			@channels[channel] = {
				:topic    => "",
				:observer => nil,
			} unless @channels.key?(channel)
			post @prefix, JOIN, m.params.first
			post nil, RPL_NAMREPLY,   @prefix.nick, "=", channel, "@#{@prefix.nick}"
			post nil, RPL_ENDOFNAMES, @prefix.nick, channel, "End of NAMES list"
		end
	end

	def on_topic(m)
		channel, topic, = m.params
		p m.params
		if @channels.key?(channel)
			post @prefix, TOPIC, channel, topic
			@channels[channel][:topic] = topic
			create_observer(channel)
		end
	end

	def create_observer(channel)
		return unless @channels.key?(channel)
		info = @channels[channel]
		@log.debug "create_observer<#{channel}>#{info.inspect}"
		begin
			info[:observer].kill if info[:observer]
		rescue
		end
		info[:observer] = Thread.start(channel, info) do |chan, i|
			file, reg, = i[:topic].split(/\s+/)
			name = File.basename(file)
			grep = Regexp.new(reg.to_s)
			@log.info "#{file} / grep => #{grep.inspect}"
			File.open(file) do |f|
				size = File.size(f)
				f.seek size
				loop do
					sleep 1
					nsize = File.size(f)
					if nsize > size
						@log.debug "follow up log"
						l = f.gets
						if grep === l
							post name, PRIVMSG, chan, l
						end
					end
					size = nsize
				end
			end
		end
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 16700,
		:host  => "localhost",
		:log   => nil,
		:debug => false,
		:foreground => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner  = <<-EOB.gsub(/^\t+/, "")
				Usage: #{$0} [opts]

			EOB

			separator ""

			separator "Options:"
			on("-p", "--port [PORT=#{opts[:port]}]", "port number to listen") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "host name or IP address to listen") do |host|
				opts[:host] = host
			end

			on("-l", "--log LOG", "log file") do |log|
				opts[:log] = log
			end

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			on("-f", "--foreground", "run foreground") do |foreground|
				opts[:log]        = $stdout
				opts[:foreground] = true
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

	def daemonize(foreground=false)
		trap("SIGINT")  { exit! 0 }
		trap("SIGTERM") { exit! 0 }
		trap("SIGHUP")  { exit! 0 }
		return yield if $DEBUG || foreground
		Process.fork do
			Process.setsid
			Dir.chdir "/"
			File.open("/dev/null") {|f|
				STDIN.reopen  f
				STDOUT.reopen f
				STDERR.reopen f
			}
			yield
		end
		exit! 0
	end

	daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], ServerLogIrcGateway, opts).start
	end
end

