require 'generators/actions'

module Rails
  module Generators
    class Error < Thor::Error
    end

    class Base < Thor::Group
      include Rails::Generators::Actions
      include Thor::Actions

      # Automatically sets the source root based on the class name.
      #
      def self.source_root
        @_rails_source_root ||= File.expand_path(File.join(File.dirname(__FILE__), base_name, generator_name, 'templates'))
      end

      # Tries to get the description from a USAGE file one folder above the source
      # root otherwise uses a default description.
      #
      def self.desc(description=nil)
        return super if description
        usage = File.expand_path(File.join(source_root, "..", "USAGE"))

        @desc ||= if File.exist?(usage)
          File.read(usage)
        else
          "Description:\n    Create #{base_name.humanize.downcase} files for #{generator_name} generator."
        end
      end

      # Convenience method to get the namespace from the class name. It's the
      # same as Thor default except that the Generator at the end of the class
      # is removed.
      #
      def self.namespace(name=nil)
        return super if name
        @namespace ||= super.sub(/_generator$/, '')
      end

      # Invoke a generator based on the value supplied by the user to the
      # given option named "name". A class option is created when this method
      # is invoked and you can set a hash to customize it.
      #
      # ==== Examples
      #
      #   class ControllerGenerator < Rails::Generators::Base
      #     hook_for :test_framework, :aliases => "-t"
      #   end
      #
      # The example above will create a test framework option and will invoke
      # a generator based on the user supplied value.
      #
      # For example, if the user invoke the controller generator as:
      #
      #   ruby script/generate controller Account --test-framework=test_unit
      #
      # The controller generator will then try to invoke the following generators:
      #
      #   "rails:generators:test_unit", "test_unit:generators:controller", "test_unit"
      #
      # In this case, the "test_unit:generators:controller" is available and is
      # invoked. This allows any test framework to hook into Rails as long as it
      # provides any of the hooks above.
      #
      # Finally, if the user don't want to use any test framework, he can do:
      #
      #   ruby script/generate controller Account --skip-test-framework
      #
      # Or similarly:
      #
      #   ruby script/generate controller Account --no-test-framework
      #
      # ==== Boolean hooks
      #
      # In some cases, you want to provide a boolean hook. For example, webrat
      # developers might want to have webrat available on controller generator.
      # This can be achieved as:
      #
      #   Rails::Generators::ControllerGenerator.hook_for :webrat, :type => :boolean
      #
      # Then, if you want, webrat to be invoked, just supply:
      #
      #   ruby script/generate controller Account --webrat
      #
      # The hooks lookup is similar as above:
      #
      #   "rails:generators:webrat", "webrat:generators:controller", "webrat"
      #
      # ==== Custom invocations
      #
      # You can also supply a block to hook_for to customize how the hook is
      # going to be invoked. The block receives two parameters, an instance
      # of the current class and the klass to be invoked.
      #
      # For example, in the resource generator, the controller should be invoked
      # with a pluralized class name. By default, it is invoked with the same
      # name as the resource generator, which is singular. To change this, we
      # can give a block to customize how the controller can be invoked.
      #
      #   hook_for :resource_controller do |instance, controller|
      #     instance.invoke controller, [ instance.name.pluralize ]
      #   end
      #
      def self.hook_for(*names, &block)
        options = names.extract_options!
        as      = options.fetch(:as, generator_name)
        verbose = options.fetch(:verbose, :white)

        names.each do |name|
          defaults = if options[:type] == :boolean
            { }
          elsif [true, false].include?(options.fetch(:default, Rails::Generators.options[name]))
            { :banner => "" }
          else
            { :desc => "#{name.to_s.humanize} to be invoked", :banner => "NAME" }
          end

          class_option name, defaults.merge!(options)
          invocations << [ name, base_name, as ]
          invocation_blocks[name] = block if block_given?

          # hook_for :test_framework
          #
          # ==== Generates
          #
          # def hook_for_test_framework
          #   return unless options[:test_framework]
          #
          #   klass_name = options[:test_framework]
          #   klass_name = :test_framework if TrueClass === klass_name
          #   klass = Rails::Generators.find_by_namespace(klass_name, "rails", "model")
          #
          #   if klass
          #     say_status :invoke, options[:test_framework], :white
          #      shell.padding += 1
          #      if block = self.class.invocation_blocks[:test_framework]
          #        block.call(self, klass)
          #      else
          #        invoke klass
          #      end
          #      shell.padding -= 1
          #   else
          #     say "Could not find and invoke '#{klass_name}'"
          #   end
          # end
          #
          class_eval <<-METHOD, __FILE__, __LINE__
            def hook_for_#{name}
              return unless options[#{name.inspect}]

              klass_name = options[#{name.inspect}]
              klass_name = #{name.inspect} if TrueClass === klass_name
              klass = Rails::Generators.find_by_namespace(klass_name, #{base_name.inspect}, #{as.inspect})

              if klass
                say_status :invoke, klass_name, #{verbose.inspect}
                shell.padding += 1
                if block = self.class.invocation_blocks[#{name.inspect}]
                  block.call(self, klass)
                else
                  invoke klass
                end
                shell.padding -= 1
              else
                say_status :error, "\#{klass_name} [not found]", :red
              end
            end
          METHOD
        end
      end

      # Remove a previously added hook.
      #
      # ==== Examples
      #
      #   remove_hook_for :orm
      #
      def self.remove_hook_for(*names)
        names.each do |name|
          remove_class_option name
          remove_task name
          invocations.delete_if { |i| i[0] == name }
          invocation_blocks.delete(name)
        end
      end

      # Make class option aware of Rails::Generators.options and Rails::Generators.aliases.
      #
      def self.class_option(name, options) #:nodoc:
        options[:desc]    = "Indicates when to generate #{name.to_s.humanize.downcase}" unless options.key?(:desc)
        options[:aliases] = Rails::Generators.aliases[name]  unless options.key?(:aliases)
        options[:default] = Rails::Generators.options[name] unless options.key?(:default)
        super(name, options)
      end

      protected

        # Check whether the given class names are already taken by user
        # application or Ruby on Rails.
        #
        def class_collisions(*class_names)
          return unless behavior == :invoke

          class_names.flatten.each do |class_name|
            class_name = class_name.to_s
            next if class_name.strip.empty?

            # Split the class from its module nesting
            nesting = class_name.split('::')
            last_name = nesting.pop

            # Hack to limit const_defined? to non-inherited on 1.9
            extra = []
            extra << false unless Object.method(:const_defined?).arity == 1

            # Extract the last Module in the nesting
            last = nesting.inject(Object) do |last, nest|
              break unless last.const_defined?(nest, *extra)
              last.const_get(nest)
            end

            if last && last.const_defined?(last_name.camelize, *extra)
              raise Error, "The name '#{class_name}' is either already used in your application " <<
                           "or reserved by Ruby on Rails. Please choose an alternative and run "  <<
                           "this generator again."
            end
          end
        end

        # Use Rails default banner.
        #
        def self.banner
          "#{$0} #{generator_name} #{self.arguments.map(&:usage).join(' ')} [options]"
        end

        # Sets the base_name taking into account the current class namespace.
        #
        def self.base_name
          @base_name ||= self.name.split('::').first.underscore
        end

        # Removes the namespaces and get the generator name. For example,
        # Rails::Generators::MetalGenerator will return "metal" as generator name.
        #
        def self.generator_name
          @generator_name ||= begin
            klass_name = self.name.split('::').last
            klass_name.sub!(/Generator$/, '')
            klass_name.underscore
          end
        end

        # Stores invocations for this class merging with superclass values.
        #
        def self.invocations #:nodoc:
          @invocations ||= from_superclass(:invocations, [])
        end

        # Stores invocation blocks used on hook_for and invoke_if.
        #
        def self.invocation_blocks #:nodoc:
          @invocation_blocks ||= from_superclass(:invocation_blocks, {})
        end

        # Overwrite class options help to allow invoked generators options to be
        # shown recursively when invoking a generator.
        #
        def self.class_options_help(shell, ungrouped_name=nil, extra_group=nil)
          group_options = Thor::CoreExt::OrderedHash.new

          get_options_from_invocations(group_options, class_options) do |klass|
            klass.send(:get_options_from_invocations, group_options, class_options)
          end

          group_options.merge!(extra_group) if extra_group
          super(shell, ungrouped_name, group_options)
        end

        # Get invocations array and merge options from invocations. Those
        # options are added to group_options hash. Options that already exists
        # in base_options are not added twice.
        #
        def self.get_options_from_invocations(group_options, base_options)
          invocations.each do |args|
            name, base, generator = args
            option = class_options[name]

            klass_name = option.type == :boolean ? name : option.default
            next unless klass_name

            klass = Rails::Generators.find_by_namespace(klass_name, base, generator)
            next unless klass

            human_name = klass_name.to_s.classify
            group_options[human_name] ||= []

            group_options[human_name] += klass.class_options.values.select do |option|
              base_options[option.name.to_sym].nil? && option.group.nil? &&
              !group_options.values.flatten.any? { |i| i.name == option.name }
            end

            yield klass if block_given?
          end
        end

        # Small macro to add ruby as an option to the generator with proper
        # default value plus an instance helper method called shebang.
        #
        def self.add_shebang_option!
          class_option :ruby, :type => :string, :aliases => "-r", :default => Thor::Util.ruby_command,
                              :desc => "Path to the Ruby binary of your choice", :banner => "PATH"

          no_tasks {
            define_method :shebang do
              @shebang ||= begin
                command = if options[:ruby] == Thor::Util.ruby_command
                  "/usr/bin/env #{File.basename(Thor::Util.ruby_command)}"
                else
                  options[:ruby]
                end
                "#!#{command}"
              end
            end
          }
        end

    end
  end
end
