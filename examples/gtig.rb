#!/usr/bin/env ruby
=begin

タスク:
10:30 21:00 にタスクを表示

カレンダー:
予定の10分前に予定を表示
07:30 今日のタスクを表示
23:30 明日のタスクを表示

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" unless defined? ::Encoding

require "pp"
require "rubygems"
require "net/irc"
require "logger"
require "pathname"
require "yaml"
require 'pit'
require 'google/api_client'

class GoogleTasksIrcGateway < Net::IRC::Server::Session
	CONFIG = Pit.get('google tasks', :require => {
		'CLIENT_ID'     => 'OAuth Client ID',
		'CLIENT_SECRET' => 'OAuth Client Secret',
	})

	CONFIG_DIR = Pathname.new("~/.gtig.rb").expand_path

	@@ctcp_action_commands = []

	class << self
		def ctcp_action(*commands, &block)
			name = "+ctcp_action_#{commands.inspect}"
			define_method(name, block)
			commands.each do |command|
				@@ctcp_action_commands << [command, name]
			end
		end
	end

	def server_name
		"tasks"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#tasks"
	end

	def config(&block)
		# merge local (user) config and global config
		merged = {}
		global = {}
		local  = {}

		global_config = CONFIG_DIR + "config"
		begin
			global = eval(global_config.read) || {}
		rescue Errno::ENOENT
		end

		local_config  = @real ? CONFIG_DIR + "#{@real}/config" : nil
		if local_config
			begin
				local = eval(local_config.read) || {}
			rescue Errno::ENOENT
			end
		end

		merged.update(global)
		merged.update(local)

		if block
			merged.instance_eval(&block)
			merged.each do |k, v|
				unless global[k] == v
					local[k] = v
				end
			end

			if local_config
				local_config.parent.mkpath
				local_config.open('w') do |f|
					PP.pp(local, f)
				end
			end
		end

		merged
	end

	COLORS = {
		"navy"        => 2,
		"aqua"        => 11,
		"teal"        => 10,
		"blue"        => 2,
		"olive"       => 7,
		"purple"      => 6,
		"lightcyan"   => 11,
		"grey"        => 14,
		"royal"       => 12,
		"white"       => 0,
		"red"         => 4,
		"orange"      => 7,
		"lightpurple" => 13,
		"pink"        => 13,
		"yellow"      => 8,
		"black"       => 1,
		"cyan"        => 11,
		"maroon"      => 5,
		"silver"      => 15,
		"lime"        => 9,
		"lightgreen"  => 9,
		"fuchsia"     => 13,
		"lightblue"   => 12,
		"lightgrey"   => 15,
		"green"       => 3,
		"brown"       => 5
	}

	def color(color, string)
		"\003%.2d%s\017" % [COLORS[color.to_s], string]
	end

	def initialize(*args)
		super
		@channels = {}
	end

	def on_disconnected
	end

	def on_user(m)
		super
		@real, *@opts = @real.split(/\s+/)
		@opts ||= []
		post @prefix, JOIN, main_channel
		init_channel(main_channel)
	end

	def on_join(m)
		channels = m.params[0].split(/ *, */)
		channels.each do |channel|
			channel = channel.split(" ", 2).first
			init_channel(channel)
		end
	end

	def on_part(m)
		channel = m.params[0]
		destroy_channel(channel)
	end

	def on_privmsg(m)
		target, mesg = *m.params
		m.ctcps.each {|ctcp| on_ctcp(target, ctcp) } if m.ctcp?
		return if mesg.empty?
		return on_ctcp_action(target, mesg) if mesg.sub!(/\A +/, "")
	end

	def on_ctcp(target, mesg)
		type, mesg = mesg.split(" ", 2)
		method = "on_ctcp_#{type.downcase}".to_sym
		send(method, target, mesg) if respond_to? method, true
	end

	def on_ctcp_action(target, mesg)
		command, *args = mesg.split(" ")
		if command
			command.downcase!

			@@ctcp_action_commands.each do |define, name|
				if define === command
					send(name, target, mesg, Regexp.last_match || command, args)
					break
				end
			end
		else
			commands = @@ctcp_action_commands.map {|define, name|
				define
			}.select {|define|
				define.is_a? String
			}

			commands.each_slice(5) do |c|
				post server_name, NOTICE, target, c.join(" ")
			end
		end

	rescue Exception => e
		post server_name, NOTICE, target, e.inspect
		e.backtrace.each do |l|
			@log.error "\t#{l}"
		end
	end

	ctcp_action "oauth" do |target, mesg, command, args|
		if args.length == 1
			auth_channel(target, args.first)
		else
			init_channel(target)
		end
	end

	def init_channel(channel)
		destroy_channel(channel) if @channels[channel]

		client = Google::APIClient.new
		client.authorization.update_token!(Marshal.load(config["token_#{channel}"])) if config["token_#{channel}"]
		client.authorization.client_id = CONFIG['CLIENT_ID']
		client.authorization.client_secret = CONFIG['CLIENT_SECRET']
		client.authorization.scope = 'https://www.googleapis.com/auth/tasks.readonly https://www.googleapis.com/auth/calendar.readonly'
		client.authorization.redirect_uri = 'urn:ietf:wg:oauth:2.0:oob'

		@channels[channel] = {
			:client   => client,
		}

		if client.authorization.access_token
			auth_channel(channel)
		else
			post server_name, NOTICE, channel, 'Access following URL: %s' % client.authorization.authorization_uri.to_s
			post server_name, NOTICE, channel, 'and send /me oauth <CODE>'
		end
	end

	def auth_channel(channel, code=nil)
		post server_name, NOTICE, channel, 'Authenticating...'
		client = @channels[channel][:client]

		client.authorization.code = code if code
		client.authorization.fetch_access_token!

		post server_name, NOTICE, channel, 'Authenticating... done'

		config {
			self["token_#{channel}"] = Marshal.dump({
				'refresh_token' => client.authorization.refresh_token,
				'access_token'  => client.authorization.access_token,
				'expires_in'    => client.authorization.expires_in
			})
		}

		@channels[channel] = {
			:client   => client,
			:tasks    => client.discovered_api('tasks'),
			:calendar => client.discovered_api('calendar', 'v3'),
		}

		observe_channel(channel)
	end

	def observe_channel(channel)
		check_tasks
		check_calendars

		@channels[channel][:thread] = Thread.start(channel) do |channel|
			loop do
				@log.info :loop
				
				now = Time.now.strftime("%H:%M")

				case now
				when "07:30"
					check_calendars(60 * 60 * 24)
				when "10:30"
					check_tasks
					check_calendars
				when "21:00"
					check_tasks
					check_calendars
				when "23:30"
					check_calendars(60 * 60 * 24)
				when /..:.0/
					check_calendars
				end

				sleep 60
			end
		end
	end

	def destroy_channel(channel)
		@channels[channel][:thread].kill rescue nil
		@channels.delete(channel)
	end

	def check_tasks
		@channels.each do |channel, info|
			@log.info "check_tasks[#{channel}]"
			client = info[:client]
			client.authorization.fetch_access_token! if client.authorization.refresh_token && client.authorization.expired?

			result = client.execute( info[:tasks].tasks.list, { 'tasklist' => '@default' })

			now = Time.now
			result.data.items.sort_by {|i| i.due ? -i.due.to_i : -(1/0.0) }.each do |task|
				next if task.status == 'completed'
				if task.due
					diff = task.due - now
					due  = diff < 0 ? color(:red, "overdue") : color(:green, "#{(diff / (60 * 60 * 24)).floor} days")
					post server_name, NOTICE, channel, "%s %s" % [due, task.title]
				else
					post server_name, NOTICE, channel, task.title
				end
			end
		end
	end

	def check_calendars(range=60*10)
		@channels.each do |channel, info|
			@log.info "check_calendars[#{channel}]"
			client = info[:client]
			client.authorization.fetch_access_token! if client.authorization.refresh_token && client.authorization.expired?

			result = client.execute( info[:calendar].calendar_list.list, {})
			calendars = result.data.items.select {|i| i.accessRole == 'owner' }

			calendars.each do |calendar|
				calendar_color = COLORS.invert[ calendar.color_id.to_i % COLORS.size ]
				result = client.execute( info[:calendar].events.list, {
					'calendarId'   => calendar.id,
					'maxResults'   => 100,
					'timeMin'      => Time.now.xmlschema,
					'timeMax'      => (Time.now + range).xmlschema,
					'singleEvents' => 'true',
					'orderBy'      => 'startTime',
					'fields'       => 'items(description,end,etag,iCalUID,id,kind,location,originalStartTime,reminders,start,status,summary,transparency,updated),nextPageToken,summary',
				})
				result.data.items.each do |item|
					post server_name, NOTICE, channel, "%s: %s~ %s" % [ color(calendar_color, calendar.summary), item.start.date || item.start.date_time.strftime('%m/%d %H:%M'), item.summary ]
				end
			end
		end
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 16720,
		:host  => "localhost",
		:log   => $stdout,
		:debug => true,
		:foreground => true,
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
		Net::IRC::Server.new(opts[:host], opts[:port], GoogleTasksIrcGateway, opts).start
	end
end

