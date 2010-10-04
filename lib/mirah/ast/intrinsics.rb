require 'fileutils'

module Duby::AST

  class Unquote < Node
    attr_accessor :value

    def initialize(parent, position, value)
      super(parent, position)
      @value = value
    end

    def infer(typer)
      raise "Unquote used outside of macro"
    end

    def _dump(depth)
      vals = Unquote.__extracted
      index = vals.size
      vals << self.value
      index.to_s
    end

    def self._load(str)
      # This just returns the exact node passed in.
      # We need to be smarter (convert strings to nodes, merge lists, etc.)
      index = str.to_i
      Unquote.__injected[index].dup
    end

    def self.__extracted
      Thread.current[:'Duby::AST::Unqote.extracted']
    end

    def self.__extracted=(value)
      Thread.current[:'Duby::AST::Unqote.extracted'] = value
    end

    def self.__injected
      Thread.current[:'Duby::AST::Unqote.injected']
    end

    def self.__injected=(value)
      Thread.current[:'Duby::AST::Unqote.injected'] = value
    end

    def self.extract_values
      values = self.__extracted = []
      begin
        yield
        return values
      ensure
        self.__extracted = nil
      end
    end

    def self.inject_values(values)
      self.__injected = values
      begin
        yield
      ensure
        self.__injected = nil
      end
    end
  end

  class MacroDefinition < Node
    include Named
    include Scoped

    child :arguments
    child :body

    attr_accessor :proxy

    def self.new(*args, &block)
      real_node = super
      real_node.proxy = NodeProxy.new(real_node)
    end

    def initialize(parent, line_number, name, &block)
      super(parent, line_number, &block)
      @name = name
    end

    def infer(typer)
      resolve_if(typer) do
        self_type = scope.static_scope.self_type
        extension_name = "%s$%s" % [self_type.name,
                                    typer.transformer.tmp("Extension%s")]
        klass = build_and_load_extension(self_type,
                                         extension_name,
                                         typer.transformer.state)

        # restore the self type since we're sharing a type factory
        typer.known_types['self'] = self_type

        arg_types = argument_types
        macro = self_type.add_compiled_macro(klass, name, arg_types)
        if arguments[-1].kind_of?(BlockArgument) && arguments[-1].optional?
          arg_types.pop
          self_type.add_method(name, arg_types, macro)
        end
        proxy.__inline__(Noop.new(parent, position))
        proxy.infer(typer)
      end
    end

    def argument_types
      arguments.map do |arg|
        if arg.kind_of?(BlockArgument)
          TypeReference::BlockType
        else
          # TODO support typed args. Also there should be a way
          # to accept any AST node.
          Duby::JVM::Types::Object
        end
      end
    end

    def signature
      args = argument_types
      if args.size > 0 && args[-1].block?
        args[-1] = BiteScript::ASM::Type.getObjectType('duby.lang.compiler.Block')
      end
      [nil] + args
    end

    def build_and_load_extension(parent, name, state)
      transformer = Duby::Transform::Transformer.new(state)
      orig_factory = Duby::AST.type_factory
      new_factory = orig_factory.dup
      Duby::AST.type_factory = new_factory
      ast = build_ast(name, parent, transformer)
      puts ast.inspect if state.verbose
      classes = compile_ast(name, ast, transformer)
      loader = DubyClassLoader.new(
          JRuby.runtime.jruby_class_loader, classes)
      klass = loader.loadClass(name, true)
      annotate(parent, name)
      Duby::AST.type_factory = orig_factory
      klass
    end

    def annotate(type, class_name)
      node = type.unmeta.node
      if node
        extension = node.annotation('duby.anno.Extensions')
        extension ||= begin
          node.annotations << Annotation.new(
              nil, nil, BiteScript::ASM::Type.getObjectType('duby/anno/Extensions'))
          node.annotations[-1].runtime = false
          node.annotations[-1]
        end
        extension['macros'] ||= []
        macro = Annotation.new(nil, nil,
                               BiteScript::ASM::Type.getObjectType('duby/anno/Macro'))
        macro['name'] = name
        macro['signature'] = BiteScript::Signature.signature(*signature)
        macro['class'] = class_name
        extension['macros'] << macro
        # TODO deal with optional blocks.
      else
        puts "Warning: No ClassDefinition for #{type.name}. Macros can't be loaded from disk."
      end
    end

    def compile_ast(name, ast, transformer)
      filename = name.gsub(".", "/")
      typer = Duby::Typer::JVM.new(filename, transformer)
      typer.infer(ast)
      typer.resolve(true)
      compiler = Duby::Compiler::JVM.new(filename)
      ast.compile(compiler, false)
      class_map = {}
      compiler.generate do |outfile, builder|
        outfile = "#{transformer.destination}#{outfile}"
        FileUtils.mkdir_p(File.dirname(outfile))
        File.open(outfile, 'wb') do |f|
          bytes = builder.generate
          name = builder.class_name.gsub(/\//, '.')
          class_map[name] = bytes
          f.write(bytes)
        end
      end
      class_map
    end

    def build_ast(name, parent, transformer)
      # TODO should use a new type factory too.
      ast = Duby::AST.parse_ruby("import duby.lang.compiler.Node")
      ast = transformer.transform(ast, nil)

      # Start building the extension class
      extension = transformer.define_class(position, name)
      #extension.superclass = Duby::AST.type('duby.lang.compiler.Macro')
      extension.implements(Duby::AST.type('duby.lang.compiler.Macro'))

      # The constructor just saves the state
      extension.define_constructor(
          position,
          ['duby', Duby::AST.type('duby.lang.compiler.Compiler')],
          ['call', Duby::AST.type('duby.lang.compiler.Call')]) do |c|
        transformer.eval("@duby = duby;@call = call", '-', c, 'duby', 'call')
      end

      node_type = Duby::AST.type('duby.lang.compiler.Node')

      # expand() parses the arguments out of call and then passes them off to
      # _expand
      expand = extension.define_method(
          position, 'expand', node_type)
      args = []
      arguments.each_with_index do |arg, i|
        # TODO optional args
        args << if arg.kind_of?(BlockArgument)
          "@call.block"
        else
          "Node(args.get(#{i}))"
        end
      end
      expand.body = transformer.eval(<<-end)
        args = @call.arguments
        _expand(#{args.join(', ')})
      end
      actual_args = arguments.map do |arg|
        type = if arg.kind_of?(BlockArgument)
          Duby::AST.type('duby.lang.compiler.Block')
        else
          node_type
        end
        [arg.name, type, arg.position]
      end
      m = extension.define_method(position, '_expand', node_type, *actual_args)
      m.body = self.body
      ast
    end
  end

  defmacro('defmacro') do |duby, fcall, parent|
    macro = fcall.args_node[0]
    block_arg = nil
    args_node = macro.args_node if macro.respond_to?(:args_node)
    body = if macro.respond_to?(:iter_node) && macro.iter_node
      macro.iter_node
    else
      fcall.iter_node
    end
    if args_node.respond_to? :getBodyNode
      block_arg = args_node.body_node
      args_node = args_node.args_node
      body = fcall.iter_node
    end
    MacroDefinition.new(parent, fcall.position, macro.name) do |mdef|
      # TODO optional args?
      args = if args_node
        args_node.map do |arg|
          case arg
          when JRubyAst::LocalAsgnNode
            OptionalArgument.new(mdef, arg.position, arg.name) do |optarg|
              # TODO check that they actually passed nil as the value
              Null.new(parent, arg.value_node.position)
            end
          when JRubyAst::VCallNode, JRubyAst::LocalVarNode
            RequiredArgument.new(mdef, arg.position, arg.name)
          end
        end
      else
        []
      end
      if block_arg
        args << BlockArgument.new(mdef, block_arg.position, block_arg.name)
        args[-1].optional = block_arg.kind_of?(JRubyAst::LocalAsgnNode)
      end
      body_node = duby.transform(body.body_node, mdef) if body.body_node
      [args,  body_node]
    end
  end

  defmacro('macro') do |transformer, fcall, parent|
    # Alternate macro syntax.
    #   macro def foo(...);...;end
    # This one supports special names like []=,
    # but you can't use optional blocks.
    method = transformer.transform(fcall.args_node[0], parent)
    macro = MacroDefinition.new(parent, fcall.position, method.name)
    macro.arguments = method.arguments.args || []
    macro.body = method.body
    macro
  end

  defmacro('puts') do |transformer, fcall, parent|
    Call.new(parent, fcall.position, "println") do |x|
      args = if fcall.respond_to?(:args_node) && fcall.args_node
        fcall.args_node.child_nodes.map do |arg|
          transformer.transform(arg, x)
        end
      else
        []
      end
      [
        Call.new(x, fcall.position, "out") do |y|
          [
            Constant.new(y, fcall.position, "System"),
            []
          ]
        end,
        args,
        nil
      ]
    end
  end

  defmacro('print') do |transformer, fcall, parent|
    Call.new(parent, fcall.position, "print") do |x|
      args = if fcall.respond_to?(:args_node) && fcall.args_node
        fcall.args_node.child_nodes.map do |arg|
          transformer.transform(arg, x)
        end
      else
        []
      end
      [
        Call.new(x, fcall.position, "out") do |y|
          [
            Constant.new(y, fcall.position, "System"),
            []
          ]
        end,
        args,
        nil
      ]
    end
  end

  class InlineCode
    def initialize(&block)
      @block = block
    end

    def inline(transformer, call)
      @block.call(transformer, call)
    end
  end
end