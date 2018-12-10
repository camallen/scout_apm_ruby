module ScoutApm
  module LayerConverters

    # Represents a random ID that we can use to track a certain request. The
    # `req` prefix is only for ease of reading logs - it should not be
    # interpreted to convey any sort of meaning.
    class RequestId
      def initialize
        @random = SecureRandom.hex(16)
      end

      def to_s
        "req-#{@random}"
      end
    end

    # Represents a random ID that we can use to track a certain span. The
    # `span` prefix is only for ease of reading logs - it should not be
    # interpreted to convey any sort of meaning.
    class SpanId
      def initialize
        @random = SecureRandom.hex(16)
      end

      def to_s
        "span-#{@random}"
      end
    end

    class TraceConverter < ConverterBase
      ###################
      #  Converter API  #
      ###################


      # Temporarily take arguments, to match up with SlowJobConverter calling into this.
      def record!(type = :web, points = nil)
        @points = points || context.slow_request_policy.score(request)

        # Let the store know we're here, and if it wants our data, it will call
        # back into #call
        @store.track_trace!(self, type)

        nil # not returning anything in the layer results ... not used
      end

      #####################
      #  ScoreItemSet API #
      #####################
      def name; request.unique_name; end
      def score; @points; end

      # Unconditionally attempts to convert this into a DetailedTrace object.
      # Can return nil if the request didn't have any scope_layer.
      def call
        return nil unless scope_layer

        # Since this request is being stored, update the needed counters
        context.slow_request_policy.stored!(request)

        # record the change in memory usage
        mem_delta = ScoutApm::Instruments::Process::ProcessMemory.new(context).rss_to_mb(@request.capture_mem_delta!)

        request_id = RequestId.new
        revision = context.environment.git_revision.sha
        start_instant = request.root_layer.start_time
        stop_instant = request.root_layer.stop_time
        type = if request.web?
                 "Web"
               elsif request.job?
                 "Job"
               else
                 "Unknown"
               end

        # Create request tags
        #
        tags = {
          :allocations => request.root_layer.total_allocations,
          :mem_delta => mem_delta,
        }.merge(request.context.to_flat_hash)

        host = context.environment.hostname
        path = request.annotations[:uri] || ""
        code = "" # User#index for instance

        spans = create_spans(request.root_layer)

        DetailedTrace.new(
          request_id,
          revision,
          host,
          start_instant,
          stop_instant,
          type,

          path,
          code,

          spans,
          tags,


          # total_score = 0,
          # percentile_score = 0,
          # age_score = 0,
          # memory_delta_score = 0,
          # memory_allocations_score = 0
        )
      end

      # Returns an array of span objects. Uses recursion to get all children
      # wired up w/ correct parent_ids
      def create_spans(layer, parent_id = nil)
        span_id = SpanId.new.to_s

        start_instant = layer.start_time
        stop_instant = layer.stop_time
        operation = layer.legacy_metric_name
        tags = {
          :start_allocations => layer.allocations_start,
          :stop_allocations => layer.allocations_stop,
        }
        if layer.desc
          tags[:desc] = layer.desc.to_s
        end
        if layer.annotations && layer.annotations[:record_count]
          tags["db.record_count"] = layer.annotations[:record_count]
        end
        if layer.annotations && layer.annotations[:class_name]
          tags["db.class_name"] = layer.annotations[:class_name]
        end
        if layer.backtrace
          tags[:backtrace] = backtrace_parser(layer.backtrace) rescue nil
        end

        # Collect up self, and all children into result array
        result = []
        result << DetailedTraceSpan.new(
          span_id.to_s,
          parent_id.to_s,
          start_instant,
          stop_instant,
          operation,
          tags)

        layer.children.each do |child|
          unless over_span_limit?(result)
            result += create_spans(child, span_id)
          end
        end

        return result
      end

      # Take an array of ruby backtrace lines and split it into an array of hashes like:
      # ["/Users/cschneid/.rvm/rubies/ruby-2.2.7/lib/ruby/2.2.0/irb/workspace.rb:86:in `eval'", ...]
      #    turns into:
      # [ {
      #     "file": "app/controllers/users_controller.rb",
      #     "line": 10,
      #     "function": "index"
      # },
      # ]
      def backtrace_parser(lines)
        lines.map do |line|
          match = line.match(/(.*):(\d+):in `(.*)'/)
          {
            "file" => match[1],
            "line" => match[2],
            "function" => match[3],
          }
        end
      end

      ################################################################################
      # Limit Handling
      ################################################################################

      # To prevent huge traces from being generated, we should stop collecting
      # spans as we go beyond some reasonably large count.

      MAX_SPANS = 500

      def over_span_limit?(spans)
        if spans.size > MAX_SPANS
          log_over_span_limit
          @limited = true
        else
          false
        end
      end

      def log_over_span_limit
        unless limited?
          context.logger.debug "Not recording additional spans for #{name}. Over the span limit."
        end
      end

      def limited?
        !! @limited
      end
    end
  end
end
