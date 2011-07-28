#!/usr/bin/env ruby
# vim:encoding=utf-8:

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
require 'mechanize'
require 'digest/sha1'

Net::HTTP.version_1_2
Thread.abort_on_exception = true

class HatenaCounterIrcGateway < Net::IRC::Server::Session
	COLORS = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

	def server_name
		"hcig"
	end

	def server_version
		"0.0.0"
	end


	def initialize(*args)
		super
		@channels = {}
		@ua = Mechanize.new
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
		self.rk = @real
		@opts ||= []
	end

	def on_join(m)
		channels = m.params.first.split(/,/)
		channels.each do |channel|
			@channels[channel] = {
				:topic    => "",
				:time     => Time.at(0),
				:interval => 60,
				:observer => nil,
			} unless @channels.key?(channel)
			create_observer(channel)
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
		when 'rk'
			self.rk = args[0]
		end
	rescue Exception => e
		@log.error e.inspect
		e.backtrace.each do |l|
			@log.error "\t#{l}"
		end
	end

	def create_observer(channel)
		info = @channels[channel]
		info[:observer].kill if info[:observer]

		@log.debug "create_observer %s, interval %d" % [channel, info[:interval]]
		info[:observer] = Thread.start(info, channel) do |info, channel|
			Thread.pass
			pre, name, cid = *channel.split(/-/)

			if !name || !cid
				post @prefix, PART, channel, "You must join to #counter-[username]-[counter id]"
				info[:observer].kill
				next
			end

			loop do
				begin
					uri = "http://counter.hatena.ne.jp/#{name}/log?cid=#{cid}&date=&type="
					@log.debug "Retriving... #{uri}"
					ret = @ua.get(uri) do |page|
						page.search('#log_table tr').reverse_each do |tr|
							access = Access.new(*tr.search('td').map {|i| i.text.gsub("\302\240", ' ').gsub(/^\s+|\s+$/, '') })
							next unless access.time
							next if access.time < info[:time]

							diff = Time.now - access.time
							time = nil
							case
							when diff < 90
								time = ''
							when Time.now.strftime('%Y%m%d') == access.time.strftime('%Y%m%d')
								time = access.time.strftime('%H:%M')
							when Time.now.strftime('%Y') == access.time.strftime('%Y')
								time = access.time.strftime('%m/%d %H:%M')
							else
								time = access.time.strftime('%Y/%m/%d %H:%M')
							end

							post access.ua_id, PRIVMSG, channel, "%s%s \003%.2d%s\017" % [
								time.empty?? "" : "#{time} ",
								access.request,
								COLORS[access.ua_id(COLORS.size)],
								access.host.gsub(/(\.\d+)+\./, '..').sub(/^[^.]+/, '')
							]
							info[:time] = access.time
						end
						info[:time] += 1
					end
					unless ret.code.to_i == 200
						post nil, NOTICE, channel, "Server returned #{code}. Please refresh rk by /me rk [new rk]"
					end
				rescue Exception => e
					@log.error "Error: #{e.inspect}"
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				@log.debug "#{channel}: sleep #{info[:interval]}"
				sleep info[:interval]
			end
		end
	end

	def rk=(rk)
		uri = URI.parse('http://www.hatena.ne.jp/')
		@ua.cookie_jar.add(
			uri,
			Mechanize::Cookie.parse(uri, "rk=#{rk}; domain=.hatena.ne.jp").first
		)
	end

	Access = Struct.new(:time_raw, :request, :ua, :lang, :screen, :host, :referrer) do
		require 'time'

		def time
			time_raw ? Time.parse(time_raw) : nil
		end

		def digest
			hostc = host.gsub(/\.[^.]+\.jp$|\.com$/, '')[/[^.]+$/]
			@digest ||= Digest::SHA1.digest([ua, lang, screen, hostc].join("\n"))
		end

		def ua_id(num=nil)
			if num
				digest.unpack("N*")[0] % num
			else
				@ua_id ||= [ digest ].pack('m')[0, 7]
			end
		end
	end

end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port       => 16801,
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
		Net::IRC::Server.new(opts[:host], opts[:port], HatenaCounterIrcGateway, opts).start
	end
end



