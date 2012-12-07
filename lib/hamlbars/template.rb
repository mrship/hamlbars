require 'tilt/template'

module Hamlbars
  class Template < Tilt::Template
    include Ext::Closure
    enable_closures! # Enable closures by default.
    include Ext::Precompiler
    if defined? Rails
      include Ext::RailsHelper
      enable_precompiler! if Rails.env.production?
    end

    JS_ESCAPE_MAP = {
      "\r\n"  => '\n',
      "\n"    => '\n',
      "\r"    => '\n',
      '"'     => '\\"',
      "'"     => "\\'"
    }

    # Used to change the asset path into a string which is
    # safe to use as a JavaScript object property.
    def self.path_translator(path)
      path.downcase.gsub(/[^a-z0-9\/]/, '_')
    end

    # Handy helper to preconfigure Hamlbars to render for
    # either :handlebars (default) or :ember.
    def self.render_templates_for(whom=:handlebars)
      if whom == :handlebars
        self.template_destination = 'Handlebars.templates'
        self.template_compiler = 'Handlebars.compile'
        self.template_partial_method = 'Handlebars.registerPartial'
      elsif whom == :ember
        self.template_destination = 'Ember.TEMPLATES'
        self.template_compiler = 'Ember.Handlebars.compile'
        self.template_partial_method = 'Ember.Handlebars.registerPartial'
      end
    end

    # The target object where the rendered template will
    # be stored on the client side.
    # Defaults to 'Handlebars.templates'
    def self.template_destination
      @template_destination ||= 'Handlebars.templates'
    end

    def self.template_destination=(x)
      @template_destination = x
    end

    # The JavaScript function used to compile the HTML
    # string into a usable Handlebars template.
    def self.template_compiler
      @template_compiler ||= 'Handlebars.compile'
    end

    def self.template_compiler=(x)
      @template_compiler = x
    end

    # The JavaScript function used on the compile side to 
    # register the template as a partial on the client side.
    def self.template_partial_method
      @template_partial_method ||= 'Handlebars.registerPartial'
    end

    def self.template_partial_method=(x)
      @template_partial_method = x
    end
    
    def self.templates_root
      @templates_root ||= ''
    end

    def self.templates_root=(root_path)
      @templates_root = root_path
    end

    self.default_mime_type = 'application/javascript'

    def self.engine_initialized?
      defined? ::Haml::Engine
    end

    def initialize_engine
      require_template_library 'haml'
    end

    def prepare
      options = @options.merge(:filename => eval_file, :line => line)
      @engine = ::Haml::Engine.new(data, options)
    end

    # Uses Haml to render the template into an HTML string, then 
    # wraps it in the neccessary JavaScript to serve to the client.
    def evaluate(scope, locals, &block)
      template = if @engine.respond_to?(:precompiled_method_return_value, true)
                   super(scope, locals, &block)
                 else
                   @engine.render(scope, locals, &block)
                 end

      if scope.respond_to? :logical_path
        path = scope.logical_path
      else
        path = basename
      end

      if basename =~ /^_/
        name = partial_path_translator(with_templates_root(path))
        "#{self.class.template_partial_method}('#{name}', '#{template.strip.gsub(/(\r\n|[\n\r"'])/) { JS_ESCAPE_MAP[$1] }}');\n"
      else
        name = self.class.path_translator(with_templates_root(path))
        "#{self.class.template_destination}[\"#{name}\"] = #{self.class.template_compiler}(\"#{template.strip.gsub(/(\r\n|[\n\r"'])/) { JS_ESCAPE_MAP[$1] }}\");\n"
      end
    end

    # Used to change the asset path into a string which is
    # safe to use as a JavaScript object property. When
    # the template is a partial (ie starts with a '_')
    def partial_path_translator(path)
      path = remove_underscore_from_partial_path(path)
      self.class.path_translator(path).gsub(%r{/}, '.')
    end
    
    def with_templates_root(path)
      self.class.templates_root.empty? ? path : "#{self.class.templates_root}/#{path}"
    end

    private

    def remove_underscore_from_partial_path(path)
      path.sub(/(.*)(\/|^)_(.+?)$/, '\1\2\3')
    end

    # Precompiled Haml source. Taken from the precompiled_with_ambles
    # method in Haml::Precompiler:
    # http://github.com/nex3/haml/blob/master/lib/haml/precompiler.rb#L111-126
    def precompiled_template(locals)
      @engine.precompiled
    end

    def precompiled_preamble(locals)
      local_assigns = super
      @engine.instance_eval do
        <<-RUBY
          begin
            extend Haml::Helpers
            _hamlout = @haml_buffer = Haml::Buffer.new(@haml_buffer, #{options_for_buffer.inspect})
            _erbout = _hamlout.buffer
            __in_erb_template = true
            _haml_locals = locals
        #{local_assigns}
        RUBY
      end
    end

    def precompiled_postamble(locals)
      @engine.instance_eval do
        <<-RUBY
        #{precompiled_method_return_value}
          ensure
            @haml_buffer = @haml_buffer.upper
          end
        RUBY
      end
    end
  end
end

module Haml
  module Helpers

    module HamlbarsExtensions
      # Used to create handlebars expressions within HAML,
      # if you pass a block then it will create a Handlebars
      # block helper (ie "{{#expression}}..{{/expression}}" 
      # otherwise it will create an expression 
      # (ie "{{expression}}").
      def handlebars(expression, options={}, &block)
        express(['{{','}}'],expression,options,&block)
      end
      alias hb handlebars

      # The same as #handlebars except that it outputs "triple-stash"
      # expressions, which means that Handlebars won't escape the output.
      def handlebars!(expression, options={}, &block)
        express(['{{{','}}}'],expression,options,&block)
      end
      alias hb! handlebars!

    private

      def make(expression, options)
        if options.any?
          expression << " " << options.map {|key, value| "#{key}=\"#{value}\"" }.join(' ')
        else
          expression
        end
      end

      def express(demarcation,expression,options={},&block)
        if block.respond_to? :call
          content = capture_haml(&block)
          output = "#{demarcation.first}##{make(expression, options)}#{demarcation.last}#{content.strip}#{demarcation.first}/#{expression.split(' ').first}#{demarcation.last}"
        else
          output = "#{demarcation.first}#{make(expression, options)}#{demarcation.last}"
        end

        output = Haml::Util.html_safe(output) if Haml::Util.rails_xss_safe?
        output
      end
    end

    include HamlbarsExtensions
  end
end

