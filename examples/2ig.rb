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
			info = @channel.delete(channel)
			info[:observer].kill if info[:observer]
			post @prefix, PART, channel
		end
	end

	def on_privmsg(m)
		target, mesg = *m.params
		m.ctcps.each {|ctcp| on_ctcp(target, ctcp) } if m.ctcp?
	end

	def on_ctcp(target, ctcp)
	end

	def on_topic(m)
		channel, topic, = m.params
		p m.params
		if @channels.key?(channel)
			info = @channels[channel]
			uri, interval = *topic.split(/\s/)
			interval = interval.to_i

			case
			when !info[:dat], uri != info[:dat].uri
				info[:dat] = ThreadData.new(uri)
				create_observer(channel)
			when info[:interval] != interval
				create_observer(channel)
			end
			info[:topic]    = topic
			info[:interval] = interval.to_i || 90

			post @prefix, TOPIC, channel, topic
		end
	end

	def create_observer(channel)
		info = @channels[channel]
		info[:observer].kill if info[:observer]

		@log.debug "create_observer %s, interval %d" % [channel, info[:interval]]
		info[:observer] = Thread.start(info, channel) do |info, channel|
			Thread.pass

			# info[:dat].retrieve(true) # 捨てる
			loop do
				begin
					sleep info[:interval]
					@log.debug "retrieving (interval %d) %s..." % [info[:interval], info[:dat].uri]
					info[:dat].retrieve.each do |line|
						post "%d{%s}" % [line.n, line.id], PRIVMSG, channel, line.aa?? encode_aa(line.body) : line.body
					end
				rescue Exception => e
					@log.error "Error: #{e.inspect}"
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
			end
		end
	end

	def encode_aa(aa)
		uri = URI('http://tinyurl.com/api-create.php')
		uri.query = 'url=' + URI.escape(<<-EOS.gsub(/[\n\t]/, ''))
		data:text/html,<pre style='font-family:"IPA モナー Pゴシック"'>#{aa.gsub(/\n/, '<br>')}</pre>
		EOS
		Net::HTTP.get(uri.host, uri.request_uri, uri.port)
	end


	class ThreadData
		attr_accessor :uri
		attr_accessor :last_modified, :size

		Line = Struct.new(:n, :name, :mail, :misc, :body, :opts, :id) do
			def aa?
				body = self.body
				return false unless body[/\n/]

				significants = body.scan(/[>\n0-9a-z０-９A-Zａ-ｚＡ-Ｚぁ-んァ-ン一-龠]/u).size.to_f
				body_length  = body.scan(/./u).size
				is_aa = 1 - significants / body_length

				is_aa > 0.6
			end
		end

		def initialize(thread_uri)
			@uri = URI(thread_uri)
			_, _, _, @board, @num, = *@uri.path.split('/')
			@dat = []
		end

		def subject
			self[0].opts
		end

		def [](n)
			l = @dat[n - 1]
			name, mail, misc, body, opts = * l.split(/<>/)
			id = misc[/ID:([^\s]+)/, 1]

			body.gsub!(/<br>/, "\n")
			body.gsub!(/<[^>]+>/, "")
			body.gsub!(/^\s+|\s+$/, "")
			body.gsub!(/&(gt|lt|amp);/) {|s|
				{ 'gt' => ">", 'lt' => "<", 'amp' => "&" }[$1]
			}

			Line.new(n, name, mail, misc, body, opts, id)
		end

		def retrieve(force=false)
			@dat = [] if @force

			res = Net::HTTP.start(@uri.host, @uri.port) do |http|
				req = Net::HTTP::Get.new('/%s/dat/%d.dat' % [@board, @num])
				req['User-Agent']        = 'Monazilla/1.00 (2ig.rb/0.0e)'
				req['Accept-Encoding']   = 'gzip' unless @size
				unless force
					req['If-Modified-Since'] = @last_modified if @last_modified
					req['Range']             = "bytes=%d-" % @size if @size
				end

				http.request(req)
			end

			ret = nil
			case res.code.to_i
			when 200, 206
				body = res.body
				if res['Content-Encoding'] == 'gzip'
					body = StringIO.open(body, 'rb') {|io| Zlib::GzipReader.new(io).read }
				end

				@last_modified = res['Last-Modified']
				if res.code == '206'
					@size += body.size
				else
					@size  = body.size
				end

				body = NKF.nkf('-w', body)

				curr = @dat.size + 1
				@dat.concat(body.split(/\n/))
				last = @dat.size

				(curr..last).map {|n|
					self[n]
				}
			when 416 # たぶん削除が発生
				p ['416']
				retrieve(true)
				[]
			when 304 # Not modified
				[]
			when 302 # dat 落ち
				p ['302', res['Location']]
				[]
			else
				p ['Unknown Status:', res.code]
				[]
			end
		end
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

