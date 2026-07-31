# frozen_string_literal: true

module Sodalite
  class RouteError < StandardError; end

  # A route is data, in the same posture as a schema: what you declare is what
  # is checked, and everything checkable is checked at build time rather than
  # on the first request that happens to exercise it.
  #
  #   Route[:get, '/users/:id',
  #     params:    { id: :integer },
  #     query:     { verbose: :boolean? },
  #     responses: { 200 => { id: :integer, name: :string } },
  #     run:       find_user >> present]
  #
  # `run` is a berylx node — a Task or any composition of them. The route holds
  # the shape; berylx holds the steps; darkcore holds the world they run in.
  class Route
    VERBS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze

    attr_reader :verb, :template, :segments, :params, :query, :body, :responses, :run, :name

    def self.[](verb, template, **)
      new(verb, template, **)
    end

    def initialize(verb, template, run:, params: {}, query: {}, body: nil, responses: {}, name: nil)
      @verb = normalize_verb(verb)
      @template = template
      @segments = parse_template(template)
      @params = TextSchema.new(params)
      @query = TextSchema.new(query)
      @body = body && Zeolite.schema(body)
      @responses = compile_responses(responses)
      @run = run
      @name = (name || "#{@verb.downcase}_#{template}").to_sym
      check_params_match_template!
      check_runnable!
      freeze
    end

    def param_names
      @segments.filter_map { |kind, value| value if kind == :param }
    end

    def declares_body?
      !@body.nil?
    end

    private

    def normalize_verb(verb)
      upcased = verb.to_s.upcase
      raise RouteError, "unknown verb #{verb.inspect}" unless VERBS.include?(upcased)

      upcased
    end

    # Segments are `[:static, text]` or `[:param, name]`. No regex, no
    # backtracking language: a template you cannot read is a route you cannot
    # reason about.
    def parse_template(template)
      raise RouteError, "template must start with '/': #{template.inspect}" unless template.start_with?('/')

      template.split('/').reject(&:empty?).map do |segment|
        segment.start_with?(':') ? [:param, segment.delete_prefix(':').to_sym] : [:static, segment]
      end.freeze
    end

    def compile_responses(responses)
      responses.to_h do |status, spec|
        check_status!(status)
        [status, spec.is_a?(Zeolite::Schema) ? spec : Zeolite.schema(spec)]
      end.freeze
    end

    def check_status!(status)
      return if status.is_a?(Integer)

      raise RouteError, "response status must be an Integer: #{status.inspect}"
    end

    # A route whose declared params do not match its template is a bug you
    # would otherwise meet at 3am, so it is a boot error.
    def check_params_match_template!
      declared = @params.keys.sort
      in_path = param_names.sort
      return if declared == in_path

      raise RouteError,
            "#{@verb} #{@template}: template params #{in_path.inspect} do not match " \
            "declared params #{declared.inspect}"
    end

    # berylx rejects a node it cannot compile. Ask it now, at boot, rather than
    # on the request that first reaches this route.
    def check_runnable!
      Berylx::EffectTree.compile(@run)
    rescue ArgumentError => e
      raise RouteError, "#{@verb} #{@template}: #{e.message}"
    end
  end
end
