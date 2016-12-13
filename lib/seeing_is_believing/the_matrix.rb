require_relative 'safe'
require_relative 'version'
require_relative 'event_stream/producer'
require 'socket'
require 'timeout'

using SeeingIsBelieving::Safe

sib_vars     = Marshal.load ENV["SIB_VARIABLES.MARSHAL.B64"].unpack('m0').first
event_stream = Timeout.timeout(1) do
  begin
    Socket.tcp("localhost", sib_vars.fetch(:event_stream_port))
  rescue Errno::ECONNREFUSED
    sleep 0.1
    retry
  end
end

$SiB = SeeingIsBelieving::EventStream::Producer.new(event_stream)
$SiB.record_ruby_version      RUBY_VERSION
$SiB.record_sib_version       SeeingIsBelieving::VERSION
$SiB.record_filename          sib_vars.fetch(:filename)
$SiB.record_num_lines         sib_vars.fetch(:num_lines)
$SiB.record_max_line_captures sib_vars.fetch(:max_line_captures)

STDOUT.sync = true
STDOUT.binmode
STDERR.binmode
STDIN.set_encoding "utf-8"
stdout, stderr = STDOUT, STDERR

finish = lambda do
  $SiB.finish!
  event_stream.close
  stdout.flush
  stderr.flush
end

real_exec      = method :exec
real_fork      = method :fork
real_exit_bang = method :exit!
fork_defn      = lambda do |*args|
  result = real_fork.call(*args)
  $SiB.send :forking_occurred_and_you_are_the_child, event_stream unless result
  result
end
Kernel.module_eval do
  private

  define_method :warn do |*args, &block|
    $stderr.puts *args
  end

  define_method :exec do |*args, &block|
    $SiB.record_exec(args)
    finish.call
    real_exec.call(*args, &block)
  end

  define_method :exit! do |status=false|
    finish.call
    real_exit_bang.call(status)
  end

  define_method :fork, &fork_defn
end

Kernel.define_singleton_method  :fork, &fork_defn
Process.define_singleton_method :fork, &fork_defn


# Some things need to be recorded and readded as they are called from Ruby C code and it blows up in really difficult to dianose ways -.-
symbol_to_s         = Symbol.instance_method(:to_s)
exception_message   = Exception.instance_method(:message)
exception_backtrace = Exception.instance_method(:backtrace)

at_exit do
  Exception.class_eval { define_method :message,   exception_message }
  Exception.class_eval { define_method :backtrace, exception_backtrace }
  Symbol.class_eval    { define_method :to_s,      symbol_to_s }
  exitstatus = ($! ? $SiB.record_exception(nil, $!) : 0)
  finish.call
  real_exit_bang.call(exitstatus) # clears exceptions so they don't print to stderr and change the processes actual exit status (we recorded what it should be)
end
