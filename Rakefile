require 'rubygems'
require "shipit"
require 'rake'
require 'rake/clean'
require 'rake/testtask'
require 'rake/packagetask'
require 'rake/gempackagetask'
require 'rake/rdoctask'
require 'rake/contrib/rubyforgepublisher'
require 'rake/contrib/sshpublisher'
require 'fileutils'
require 'spec'
require 'spec/rake/spectask'

include FileUtils

$LOAD_PATH.unshift "lib"
require "net/irc"

NAME              = "net-irc"
AUTHOR            = "cho45"
EMAIL             = "cho45@lowreal.net"
DESCRIPTION       = ""
RUBYFORGE_PROJECT = "lowreal"
HOMEPATH          = "http://#{RUBYFORGE_PROJECT}.rubyforge.org"
BIN_FILES         = %w(  )
VERS              = Net::IRC::VERSION

REV = File.read(".svn/entries")[/committed-rev="(d+)"/, 1] rescue nil
CLEAN.include ['**/.*.sw?', '*.gem', '.config']
RDOC_OPTS = [
	'--title', "#{NAME} documentation",
	"--charset", "utf-8",
	"--opname", "index.html",
	"--line-numbers",
	"--main", "README",
	"--inline-source",
]

task :default => [:test]
task :package => [:clean]

Rake::TestTask.new("test") do |t|
	t.libs   << "test"
	t.pattern = "test/**/*_test.rb"
	t.verbose = true
end

spec = Gem::Specification.new do |s|
	s.name              = NAME
	s.version           = VERS
	s.platform          = Gem::Platform::RUBY
	s.has_rdoc          = true
	s.extra_rdoc_files  = ["README", "ChangeLog"]
	s.rdoc_options     += RDOC_OPTS + ['--exclude', '^(examples|extras)/']
	s.summary           = DESCRIPTION
	s.description       = DESCRIPTION
	s.author            = AUTHOR
	s.email             = EMAIL
	s.homepage          = HOMEPATH
	s.executables       = BIN_FILES
	s.rubyforge_project = RUBYFORGE_PROJECT
	s.bindir            = "bin"
	s.require_path      = "lib"
	s.autorequire       = ""
	s.test_files        = Dir["test/test_*.rb"]

	#s.add_dependency('activesupport', '>=1.3.1')
	#s.required_ruby_version = '>= 1.8.2'

	s.files = %w(README ChangeLog Rakefile) +
		Dir.glob("{bin,doc,test,lib,templates,generator,extras,website,script}/**/*") + 
		Dir.glob("ext/**/*.{h,c,rb}") +
		Dir.glob("examples/**/*.rb") +
		Dir.glob("tools/*.rb")

	s.extensions = FileList["ext/**/extconf.rb"].to_a
end

Rake::GemPackageTask.new(spec) do |p|
	p.need_tar = true
	p.gem_spec = spec
end

task :install do
	name = "#{NAME}-#{VERS}.gem"
	sh %{rake package}
	sh %{sudo gem install pkg/#{name}}
end

task :uninstall => [:clean] do
	sh %{sudo gem uninstall #{NAME}}
end


Rake::RDocTask.new do |rdoc|
	rdoc.rdoc_dir = 'html'
	rdoc.options += RDOC_OPTS
	rdoc.template = "resh"
	#rdoc.template = "#{ENV['template']}.rb" if ENV['template']
	if ENV['DOC_FILES']
		rdoc.rdoc_files.include(ENV['DOC_FILES'].split(/,\s*/))
	else
		rdoc.rdoc_files.include('README', 'ChangeLog')
		rdoc.rdoc_files.include('lib/**/*.rb')
		rdoc.rdoc_files.include('ext/**/*.c')
	end
end

desc "Publish to RubyForge"
task :rubyforge => [:rdoc, :package] do
	require 'rubyforge'
	@local_dir = "html"
	@host = "cho45@rubyforge.org"
	@remote_dir = "/var/www/gforge-projects/#{RUBYFORGE_PROJECT}/#{NAME}"
	sh %{rsync -r --delete --verbose #{@local_dir}/ #{@host}:#{@remote_dir}}
end

Rake::ShipitTask.new do |s|
	s.Step.new {
		system("svn", "up")
	}.and {}
	s.Step.new {
		raise "changelog-with-hatenastar.rb is not found" unless system("which", "changelog-with-hatenastar.rb")
	}.and {
		system("changelog-with-hatenastar.rb > ChangeLog")
	}
	s.ChangeVersion "lib/net/irc.rb", "VERSION"
	s.Commit
	s.Task :clean, :package
	s.RubyForge
	s.Tag
	s.Twitter
	s.Task :rubyforge
end

desc "Run the specs under spec/models"
Spec::Rake::SpecTask.new do |t|
	t.spec_opts = ['--options', "spec/spec.opts"]
	t.spec_files = FileList['spec/*_spec.rb']
end
