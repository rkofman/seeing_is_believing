require 'seeing_is_believing/event_stream/events'
require 'thread'

class SeeingIsBelieving
  module EventStream
    class Producer

      module NullQueue
        extend self
        def <<(*)   end
        def shift() end
      end

      attr_accessor :max_line_captures, :num_lines, :filename

      def initialize(resultstream)
        self.filename          = nil
        self.max_line_captures = Float::INFINITY
        self.num_lines         = 0
        self.recorded_results  = []
        self.queue             = Queue.new
        self.producer_thread   = Thread.new do
          begin
            resultstream.sync = true
            loop do
              to_publish = queue.shift
              break if to_publish == :break
              resultstream << (to_publish << "\n")
            end
          rescue IOError, Errno::EPIPE
            queue.clear
          ensure
            resultstream.flush rescue nil
          end
          self.queue = NullQueue
        end
      end

      attr_reader :version
      alias ver version
      def record_sib_version(sib_version)
        @version = sib_version
        queue << "sib_version #{to_string_token sib_version}"
      end

      def record_ruby_version(ruby_version)
        queue << "ruby_version #{to_string_token ruby_version}"
      end

      def record_max_line_captures(max_line_captures)
        self.max_line_captures = max_line_captures
        queue << "max_line_captures #{max_line_captures}"
      end

      StackErrors = [SystemStackError]
      StackErrors << Java::JavaLang::StackOverflowError if defined?(RUBY_PLATFORM) && RUBY_PLATFORM == 'java'
      def record_result(type, line_number, value)
        self.num_lines = line_number if num_lines < line_number
        counts = recorded_results[line_number] ||= Hash.new(0)
        count  = counts[type]
        recorded_results[line_number][type] = count.next
        if count < max_line_captures
          begin
            if block_given?
              inspected = yield(value).to_str
            else
              inspected = value.inspect.to_str
            end
          rescue *StackErrors
            # this is necessary because SystemStackError won't show the backtrace of the method we tried to call
            # which means there won't be anything showing the user where this came from
            # so we need to re-raise the error to get a backtrace that shows where we came from
            # otherwise it looks like the bug is in SiB and not the user's program, see https://github.com/JoshCheek/seeing_is_believing/issues/37
            raise SystemStackError, "Calling inspect blew the stack (is it recursive w/o a base case?)"
          rescue Exception
            inspected = "#<no inspect available>"
          end
          queue << "result #{line_number} #{type} #{to_string_token inspected}"
        elsif count == max_line_captures
          queue << "maxed_result #{line_number} #{type}"
        end
        value
      end

      # records the exception, returns the exitstatus for that exception
      def record_exception(line_number, exception)
        if line_number
          self.num_lines = line_number if num_lines < line_number
        elsif filename
          begin
            line_number = exception.backtrace.grep(/#{filename}/).first[/:\d+/][1..-1].to_i
          rescue Exception
          end
        end
        line_number ||= -1
        queue << "exception"
        queue << "  line_number #{line_number}"
        queue << "  class_name  #{to_string_token exception.class.name}"
        queue << "  message     #{to_string_token exception.message}"
        exception.backtrace.each { |line|
          queue << "  backtrace   #{to_string_token line}"
        }
        queue << "end"
        exception.kind_of?(SystemExit) ? exception.status : 1
      end

      def record_filename(filename)
        self.filename = filename
        queue << "filename #{to_string_token filename}"
      end

      def record_exitstatus(status)
        exit status
      rescue SystemExit
        queue << "exitstatus #{$!.status}"
      end

      # TODO: do we even want to bother with the number of lines?
      # note that producer will continue reading until stream is closed
      def finish!
        queue << "num_lines #{num_lines}"
        queue << :break
        producer_thread.join
      end

      private

      attr_accessor :resultstream, :queue, :producer_thread, :recorded_results

      # for a consideration of many different ways of doing this, see 5633064
      def to_string_token(string)
        [Marshal.dump(string.to_s)].pack('m0')
      end
    end
  end
end
