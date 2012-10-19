#!/usr/bin/env ruby
# vim:encoding=UTF-8:

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" if RUBY_VERSION < "1.9" # json use this

require "rubygems"
require "net/irc"
require "logger"
require "pathname"
require "yaml"
require 'uri'
require 'net/http'
require 'nkf'
require 'stringio'
require 'zlib'

require "#{Pathname.new(__FILE__).parent.expand_path}/2ch.rb"
Net::HTTP.version_1_2

class NiChannelIrcGateway < Net::IRC::Server::Session
	def server_name
		"2ch"
	end

	def server_version
		"0.0.0"
	end


	def initialize(*args)
		super
		@channels = {}
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
				:dat      => nil,
				:interval => nil,
				:observer => nil,
			} unless @channels.key?(channel)
			post @prefix, JOIN, channel
			post nil, RPL_NAMREPLY,   @prefix.nick, "=", channel, "@#{@prefix.nick}"
			post nil, RPL_ENDOFNAMES, @prefix.nick, channel, "End of NAMES list"
		end
	end

	def on_part(m)
		channel = m.params[0]
		if @channels.key?(channel)
			info = @channels.delete(channel)
			info[:observer].kill if info[:observer]
			post @prefix, PART, channel
		end
	end

	def on_privmsg(m)
		target, mesg = *m.params
		m.ctcps.each {|ctcp| on_ctcp(target, ctcp) } if m.ctcp?
	end

	def on_ctcp(target, mesg)
		type, mesg = mesg.split(" ", 2)
		method = "on_ctcp_#{type.downcase}".to_sym
		send(method, target, mesg) if respond_to? method, true
	end

	def on_ctcp_action(target, mesg)
		command, *args = mesg.split(" ")
		command.downcase!

		case command
		when 'next'
			if @channels.key?(target)
				guess_next_thread(target)
			end
		end
	rescue Exception => e
		@log.error e.inspect
		e.backtrace.each do |l|
			@log.error "\t#{l}"
		end
	end

	def on_topic(m)
		channel, topic, = m.params
		p m.params
		if @channels.key?(channel)
			info = @channels[channel]

			unless topic
				post nil, '332', channel, info[:topic]
				return
			end

			uri, interval = *topic.split(/\s/)
			interval = interval.to_i

			post @prefix, TOPIC, channel, topic

			case
			when !info[:dat], uri != info[:dat].uri
				post @prefix, NOTICE, channel, "Thread URL has been changed."
				info[:dat] = ThreadData.new(uri)
				create_observer(channel)
			when info[:interval] != interval
				post @prefix, NOTICE, channel, "Interval has been changed."
				create_observer(channel)
			end
			info[:topic]    = topic
			info[:interval] = interval > 0 ? interval : 90
		end
	end

	def guess_next_thread(channel)
		info = @channels[channel]
		post server_name, NOTICE, channel, "Current Thread: #{info[:dat].subject}"
		threads = info[:dat].guess_next_thread
		threads.first(3).each do |t|
			if t[:continuous_num] && t[:appear_recent]
				post server_name, NOTICE, channel, "#{t[:uri]} \003%d#{t[:subject]}\017" % 10
			else
				post server_name, NOTICE, channel, "#{t[:uri]} #{t[:subject]}"
			end
		end
		threads
	end

	def create_observer(channel)
		info = @channels[channel]
		info[:observer].kill if info[:observer]

		@log.debug "create_observer %s, interval %d" % [channel, info[:interval].to_i]
		info[:observer] = Thread.start(info, channel) do |info, channel|
			Thread.pass

			loop do
				begin
					sleep info[:interval]
					@log.debug "retrieving (interval %d) %s..." % [info[:interval], info[:dat].uri]
					info[:dat].retrieve.last(100).each do |line|
						priv_line channel, line
					end

					if info[:dat].length >= 1000
						post server_name, NOTICE, channel, "Thread is over 1000. Guessing next thread..."
						guess_next_thread(channel)
						break
					end
				rescue UnknownThread
					# pass
				rescue Exception => e
					@log.error "Error: #{e.inspect}"
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
			end
		end
	end

	def priv_line(channel, line)
		post "%d{%s}" % [line.n, line.id], PRIVMSG, channel, line.aa?? encode_aa(line.body) : line.body
	end

	def encode_aa(aa)
		uri = URI('http://tinyurl.com/api-create.php')
		uri.query = 'url=' + URI.escape(<<-EOS.gsub(/[\n\t]/, ''))
		data:text/html,<pre style='font-family:"IPA モナー Pゴシック"'>#{aa.gsub(/\n/, '<br>')}</pre>
		EOS
		Net::HTTP.get(uri.host, uri.request_uri, uri.port)
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port       => 16701,
		:host       => "localhost",
		:log        => nil,
		:debug      => false,
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
		Net::IRC::Server.new(opts[:host], opts[:port], NiChannelIrcGateway, opts).start
	end
end

