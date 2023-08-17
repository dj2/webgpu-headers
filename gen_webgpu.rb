#!/usr/bin/env ruby

require 'rexml/document'

IN = :in
OUT = :out

# A defined constant
#   name: The name of the constant
#   type: The type of the constant
#  value: The constant value
Define = Struct.new(:name, :type, :value)

# A function argument
#        name: The argument name
#        type: The argument type
#  annotation: Any annotations attached to the argument
#      length: How the length of the argument is stored, if any
#    optional: If the argument is optional (will be `true` or `false`)
#     default: A default value, if provided
Argument = Struct.new(:name, :type, :annotation, :length, :optional, :default)

# A function (e.g. WGPUCreateInstance)
#    name: The function name
#  return: The return type
#   async: `true` if the function is async. The `return` is implicitly `void`.
#      cb: If the function is `async` and the async callback name does not match `<name>Callback`
#    args: The arguments
Function = Struct.new(:name, :return, :async, :cb, :args)

# An object (e.g. WGPUInstance)
#        name: The object name
#     methods: The object methods (Function objects)
#  refcounted: `true` if this object is ref counted
Klass = Struct.new(:name, :methods, :refcounted)

# A value type (e.g. WGPUBool, WGPUFlags)
#  name: The name of the value type
#  type: The type of the value
TypeValue = Struct.new(:name, :type)

# An enum value
#   name: The name of the enum value
#  value: The value of the enum value
TypeNamedValue = Struct.new(:name, :value)

# An enum type (e.g. WGPURequestAdapterStatus
#    name: The name of the enum
#  values: The values stored in the enum (TypeNamedValue items)
TypeEnum = Struct.new(:name, :values)

# A bitmask type (e.g. WGPUBufferUsage
#    name: The name of the bitmask
#  values: The values stored in the bitmask (TypeNamedValue items)
TypeBitmask = Struct.new(:name, :values)

# A structure member
#        name: The member name
#        type: The member type
#  annotation: Any member annotations
#      length: Where the length is stored, if any
#     default: The default value
TypeStructMember = Struct.new(:name, :type, :annotation, :length, :default, :optional)

# A structure type (e.g. WGPUAdapterProperties)
#         name: The structure name
#      members: The structure members
#      methods: Any methods attached to the structure
#   extensible: If the structure is extensible. Values are `IN` or `OUT`
#      chained: If the structure can be chained. Values are `IN` or `OUT`
#   chained_to: Lists the structures this structure can be chained too
TypeStruct = Struct.new(:name, :members, :methods, :extensible, :chained, :chained_to)

###
### XML Input Processing Routines
###

# Retrieves the text content of the `key` element nested below the `node` root element
def text_of_first(node, key)
  n = REXML::XPath.first(node, key)
  n = n.text unless n.nil?
  n
end

# Retrieves the symbol of the `key` element nested below the `node` root element, or `nil` if no
# element found.
def sym_or_nil_of_first(node, key)
    val = REXML::XPath.first(node, key)
    val = val.text.to_sym unless val.nil?
    val
end

# Retrieves the symbol of the `key` attribute of `node` root element, or `nil` if no attribute found
def sym_or_nil_of_attr(node, key)
    val = node[key]
    val = val.text.to_sym unless val.nil?
    val
end

# Gather up all the define elements, returns a hash of name symbol to Define
def gather_defines(root)
  defines = {}
  # Gather up the defines
  REXML::XPath.each(root, 'define') do |define|
    name = define['name']
    type = to_type_name(define['type'])

    value = case define['value']
    when 'UINT64_MAX' then '(0xffffffffffffffffULL)'
    when 'UINT32_MAX' then '(0xffffffffUL)'
    else define['value']
    end

    defines[name.to_sym] = Define.new(name, type, value)
  end
  defines
end

# Gathers all of the TypeNamedValue items
def gather_enum_values(root)
  values = []
  REXML::XPath.each(root, 'value') do |member|
    name = member['name']
    value = member['value']
    values << TypeNamedValue.new(name, value)
  end
  values
end

# Gathers all of the TypeEnum items
def gather_enums(root, types)
  REXML::XPath.each(root, "type[@kind='enum']") do |enum|
    name = text_of_first(enum, 'name')
    values = gather_enum_values(enum)
    types[name.to_sym] = TypeEnum.new(name, values)
  end
end

# Gathers all of the TypeBitmask items
def gather_bitmasks(root, types)
  REXML::XPath.each(root, "type[@kind='bitmask']") do |bitmask|
    name = text_of_first(bitmask, 'name')
    values = gather_enum_values(bitmask)
    types[name.to_sym] = TypeBitmask.new(name, values)
  end
end

# Gather up all the members of the given struct
def gather_struct_members(root)
  members = []
  REXML::XPath.each(root, 'members/member') do |member|
    name = member['name']
    type = to_type_name(member['type'])
    annotation = member['annotation']
    length = member['length']
    default = member['default']
    optional = member['optional']
    members << TypeStructMember.new(name, type, annotation, length, default, optional)
  end
  members
end

# Gathers up all the TypeStruct items
def gather_structs(root, types)
  REXML::XPath.each(root, "type[@kind='struct']") do |value|
    name = text_of_first(value, 'name')
    extensible = sym_or_nil_of_first(value, 'extensible')
    chained = sym_or_nil_of_first(value, 'chained/dir')
    members = gather_struct_members(value)

    methods = {}
    gather_functions_from_path(value, 'methods', methods)

    chained_to = []
    unless chained.nil?
      REXML::XPath.each(value, 'chained/root') do |root|
        chained_to << root.text.to_sym
      end
    end

    types[name.to_sym] = TypeStruct.new(name, members, methods, extensible, chained, chained_to)
  end
end

# Gathers up all the TypeValue items
def gather_values(root, types)
  REXML::XPath.each(root, "type[@kind='value']") do |value|
    name = text_of_first(value, 'name')
    type = text_of_first(value, 'kind')
    types[name.to_sym] = TypeValue.new(name, type)
  end
end

# Gather up all the type elements, returns a hash of name symbol to {Struct | Enum | Bitmask | Value}
def gather_types(root)
  types = {
    structs: {},
    bitmasks: {},
    enums: {},
    values: {}
  }
  gather_enums(root, types[:enums])
  gather_bitmasks(root, types[:bitmasks])
  gather_structs(root, types[:structs])
  gather_values(root, types[:values])
  types
end

# Gets a type from the XML node. If the type is an internal object or struct will be returned as a
# symbol, otherwise the type is a primitive and will be a string
def get_type(root, name)
  n = text_of_first(root, name)
  to_type_name(n)
end

# Cleans up the type name
def to_type_name(n)
  return nil if n.nil?
  n = n.to_sym if n[0] == n[0].upcase
  n
end

# Gathers all of the arguments at the given root
def gather_args(root)
  args = []
  REXML::XPath.each(root, 'arg') do |arg|
    name = arg['name']
    type = to_type_name(arg['type'])
    annotation = arg['annotation']
    length = arg['length']
    optional = arg['optional']
    default = arg['default']

    args << Argument.new(name, type, annotation, length, optional, default)
  end
  args
end

# Gathers all the functions from the given `path`
def gather_functions_from_path(root, path, functions)
  REXML::XPath.each(root, "#{path}/function").each do |func|
    name = func['name']
    ret = to_type_name(func['return'])
    async = func['async']
    cb = to_type_name(func['cb'])
    args = gather_args(func)
    functions[name.to_sym] = Function.new(name, ret, async, cb, args)
  end
end

# Gather all the free functions and function pointers
def gather_functions(root)
  functions = {
    free: {},
    pointers: {}
  }
  gather_functions_from_path(root, 'free_functions', functions[:free])
  gather_functions_from_path(root, 'function_pointers', functions[:pointers])
  functions
end

# Gathers all of the object (Klass) items
def gather_objects(root)
  objs = {}
  REXML::XPath.each(root, 'object') do |obj|
    name = text_of_first(obj, 'name')
    methods = {}
    gather_functions_from_path(obj, 'methods', methods)

    objs[name.to_sym] = Klass.new(name, methods, !!obj['refcounted'])
  end
  objs
end

###
### Output Formatters
###

# Formats the data into a C header
class FormatCHeader
  attr_accessor :license, :prefix, :defines, :types, :functions, :objects, :hdr

  NO_NULLABLE = :no_nullable
  TAG_STRUCTS = :tag_structs

  def initialize(license, prefix, defines, types, functions, objects)
    self.license = license
    self.prefix = prefix
    self.defines = defines
    self.types = types
    self.functions = functions
    self.objects = objects
  end

  def to_s
    generate
    self.hdr.string
  end

  def generate
    self.hdr = StringIO.new

    emit_license

    hdr.puts "#ifndef WEBGPU_H_"
    hdr.puts "#define WEBGPU_H_"
    hdr.puts

    emit_preamble

    hdr.puts "#include <stdint.h>"
    hdr.puts "#include <stddef.h>"
    hdr.puts

    emit_constants
    emit_value_types
    emit_object_impl_typedefs
    emit_struct_forward_decls
    emit_enums
    emit_bitmasks
    emit_function_pointers
    emit_structs

    emit_begin_extern_c
    hdr.puts

    emit_defined_block("#{prefix}_SKIP_PROCS") { emit_procs }
    hdr.puts
    emit_defined_block("#{prefix}_SKIP_DECLARATIONS") { emit_declarations }
    hdr.puts

    emit_end_extern_c
    hdr.puts

    hdr.puts "#endif // WEBGPU_H_"
  end

  def def_name(name); "#{prefix}_#{name}"; end
  def attr_name(name); "#{name}_ATTRIBUTE"; end
  def attr(name); def_name(attr_name(name)); end
  def object_attr; attr("OBJECT"); end
  def enum_attr; attr("ENUM"); end
  def struct_attr; attr("STRUCTURE"); end
  def func_attr; attr("FUNCTION"); end
  def nullable; def_name("NULLABLE"); end
  def export; def_name("EXPORT"); end
  def to_n(name); "#{prefix}#{name}"; end


  def emit_begin_extern_c
    hdr.puts <<~HERE
    #ifdef __cplusplus
    extern "C" {
    #endif
HERE
  end

  def emit_end_extern_c
    hdr.puts <<~HERE
    #ifdef __cplusplus
    } // extern "C"
    #endif
HERE
  end

  def emit_defined_block(guard, &blk)
    hdr.puts "#if !defined(#{guard})"
    hdr.puts
    yield
    hdr.puts "#endif  // !defined(#{guard})"
  end

  # Emit all of the defined constants
  def emit_constants
    defines.keys.sort_by(&:to_s).each do |key|
      define = defines[key]
      hdr.puts "#define #{prefix}_#{define.name} #{define.value}"
    end
    hdr.puts
  end

  # Emit all of the value types
  def emit_value_types
    types[:values].keys.sort_by(&:to_s).reverse.each do |key|
      ty = types[:values][key]
      hdr.puts "typedef #{ty.type} #{to_n(ty.name)};"
    end
    hdr.puts
  end

  # Emit typedefs for the object implementations
  def emit_object_impl_typedefs
    objects.keys.sort_by(&:to_s).each do |key|
      obj = objects[key]
      hdr.puts "typedef struct #{to_n(obj.name)}Impl* #{to_n(obj.name)} #{object_attr};"
    end
    hdr.puts
  end

  def emit_struct_forward_decls
    hdr.puts "// Structure forward declarations"
    sorted_structures.each do |key|
      struct = types[:structs][key]
      hdr.puts "struct #{to_n(struct.name)};"
    end
    hdr.puts
  end

  def sorted_structures
    def compute_depth(s, depths)
      return depths[s.name].depth if depths.has_key?(s.name)

      max_subdepth = 0
      s.members.each do |m|
        if types[:structs].has_key?(m.type)
          max_subdepth = [max_subdepth, compute_depth(types[:structs][m.type], depths) + 1].max
        end
      end

      data = Struct.new(:key, :depth)
      depths[s.name.to_sym] = data.new(s.name, max_subdepth)
      max_subdepth
    end
    depths = {}
    types[:structs].values.each { |val| compute_depth(val, depths) }

    # Ruby sort is not stable, so take the sorted list of keys, and then sort that by the
    # [depth, position] to get a stable alphabetical sort by depth
    types[:structs].keys.sort_by(&:to_s).sort_by.with_index { |a, idx| [depths[a].depth, idx] }
  end

  def emit_enums
    types[:enums].keys.sort_by(&:to_s).each do |key|
      emit_enum_data(types[:enums][key])
      hdr.puts
    end
  end

  def emit_bitmasks
    types[:bitmasks].keys.sort_by(&:to_s).each do |key|
      bm = types[:bitmasks][key]
      emit_enum_data(bm)
      hdr.puts "typedef #{to_n('Flags')} #{to_n(bm.name)}Flags #{enum_attr};"
      hdr.puts
    end
  end

  def emit_enum_data(enum)
    name = to_n(enum.name)

    hdr.puts "typedef enum #{name} {"
    enum.values.each do |val|
      val_name = "#{val.name[0].upcase}#{val.name[1..]}"
      hdr.puts "    #{name}_#{val_name} = 0x#{format_as_hex(val.value)},"
    end
    hdr.puts "    #{name}_Force32 = 0x7FFFFFFF"
    hdr.puts "} #{name} #{enum_attr};"
  end

  def emit_function_pointers
    functions[:pointers].keys.sort_by(&:to_s).each do |key|
      fp = functions[:pointers][key]
      type = format_type(fp.return)
      name = to_n(fp.name)
      args = format_args('', fp, NO_NULLABLE, TAG_STRUCTS)

      hdr.puts "typedef #{type} (*#{name})#{args} #{func_attr};"
    end
    hdr.puts
  end

  def emit_struct(struct)
    chain_in = struct.chained == IN
    chain_out = struct.chained == OUT
    extend_in = struct.extensible == IN
    extend_out = struct.extensible == OUT

    if (chain_in || chain_out) && !struct.chained_to.empty?
      hdr.puts "// Can be chained in #{struct.chained_to.map {|x| to_n(x) }.join(", ")}"
    end
    hdr.puts "typedef struct #{to_n(struct.name)} {"
    hdr.puts "    #{to_n('ChainedStruct')} const * nextInChain;" if extend_in
    hdr.puts "    #{to_n('ChainedStruct')} chain;" if chain_in
    hdr.puts "    #{to_n('ChainedStructOut')} * nextInChain;" if chain_out || extend_out

    struct.members.each do |mem|
      nullable = if mem.optional then "#{self.nullable} "; else ''; end
      annot = if mem.annotation then "#{mem.annotation} "; else ''; end
      hdr.puts "    #{nullable}#{format_type(mem.type)} #{annot}#{mem.name};"
    end

    hdr.puts "} #{to_n(struct.name)} #{struct_attr};"
    hdr.puts
  end

  def emit_structs
    chained_in = TypeStruct.new('ChainedStruct', [
      TypeStructMember.new('next', "struct #{to_n('ChainedStruct')}", 'const *'),
      TypeStructMember.new('sType', :SType)
    ])
    emit_struct(chained_in)

    chained_out = TypeStruct.new('ChainedStructOut', [
      TypeStructMember.new('next', "struct #{to_n('ChainedStructOut')} *"),
      TypeStructMember.new('sType', :SType)
    ])
    emit_struct(chained_out);

    sorted_structures.each do |key|
      struct = types[:structs][key]
      emit_struct(struct)
    end
  end

  def emit_all_functions(name, &blk)
    functions[:free].keys.sort_by(&:to_s).each do |key|
      func = functions[:free][key]
      yield('', func)
    end
    hdr.puts

    objects.keys.sort_by(&:to_s).each do |key|
      obj = objects[key]

      hdr.puts "// #{name} of #{obj.name}"
      obj.methods.keys.sort_by(&:to_s).each do |mtd_key|
        mtd = obj.methods[mtd_key]
        yield(obj.name, mtd)
      end

      if obj.refcounted
        yield(obj.name, Function.new('Reference', 'void', nil, nil, []))
        yield(obj.name, Function.new('Release', 'void', nil, nil, []))
      end
      hdr.puts
    end

    sorted_structures.each do |key|
      struct = types[:structs][key]
      next if struct.methods.empty?

      hdr.puts "// #{name} of #{struct.name}"
      struct.methods.keys.sort_by(&:to_s).each do |s_key|
        m = struct.methods[s_key]
        yield(struct.name, m)
      end
      hdr.puts
    end
  end

  def emit_procs
    emit_all_functions('Procs') do |obj, func|
      name = "#{to_n('Proc')}#{obj}#{func.name}"
      ret = if func.async; 'void'; else format_type(func.return); end
      args = format_args(obj, func)
      hdr.puts "typedef #{ret} (*#{name})#{args} #{func_attr};"
    end
  end

  def emit_declarations
    emit_all_functions("Methods") do |obj, func|
      name = "#{prefix.downcase}#{obj}#{func.name}"
      ret = if func.async; 'void'; else format_type(func.return); end
      args = format_args(obj, func)
      hdr.puts "#{export} #{ret} #{name}#{args} #{func_attr};"
    end
  end

  def emit_license
    trim = 0
    trim = $1.length - 1 if license =~ /^(\s+)/

    lines = license.split("\n")
    lines.shift if lines.first =~ /^\s*$/  # Strip blank first line
    lines.pop if lines.last =~ /^\s*$/  # Strip blank last line

    hdr.puts lines.map { |l| "// #{l[trim..]}".strip }.join("\n")
  end

  def define_block(name)
    hdr.puts <<~HERE
      #if !defined(#{def_name(name)})
      #define #{def_name(name)}
      #endif
HERE
  end

  def emit_preamble
    hdr.puts <<~HERE
      #if defined(#{prefix}_SHARED_LIBRARY)
      #    if defined(_WIN32)
      #        if defined(#{prefix}_IMPLEMENTATION)
      #            define #{prefix}_EXPORT __declspec(dllexport)
      #        else
      #            define #{prefix}_EXPORT __declspec(dllimport)
      #        endif
      #    else  // defined(_WIN32)
      #        if defined(#{prefix}_IMPLEMENTATION)
      #            define #{prefix}_EXPORT __attribute__((visibility("default")))
      #        else
      #            define #{prefix}_EXPORT
      #        endif
      #    endif  // defined(_WIN32)
      #else       // defined(#{prefix}_SHARED_LIBRARY)
      #    define #{prefix}_EXPORT
      #endif  // defined(#{prefix}_SHARED_LIBRARY)

HERE

    # Emit the _ATTRBIUTE defines
    %w(OBJECT ENUM STRUCTURE FUNCTION).each { |name| define_block(attr_name(name)) }
    # Emit other defines
    %w(NULLABLE).each { |name| define_block('NULLABLE') }
    hdr.puts
  end

  def format_args(obj, func, nullable = nil, tagged_structs = nil)
    return "(void)" if func.args.empty? && (obj.nil? || obj.empty?) && !func.async

    ret = "("
    first = true

    if !obj.nil? && !obj.empty?
      name = "#{obj[0].downcase}#{obj[1..]}"
      ret += "#{to_n(obj)} #{name}"
      first = false
    end

    func.args.each do |a|
      ret += ", " unless first
      first = false

      ret += "#{self.nullable} " if nullable != NO_NULLABLE && a.optional
      ret += "struct " if tagged_structs == TAG_STRUCTS && types[:structs].has_key?(a.type)
      ret += "#{format_type(a.type)} "
      ret += "#{a.annotation} " unless a.annotation.nil?
      ret += a.name
    end

    if func.async
      ret += ", " unless first
      first = false

      cb_name = func.cb || "#{func.name}Callback".to_sym
      ret += "#{format_type(cb_name)} callback, void * userdata"
    end

    ret += ")"
    ret
  end

  def format_as_hex(val)
    v = "%.8x" % val.to_i
    v.upcase
  end

  def format_type(ty)
    # Convert to WGPUBool from bool
    ty = :Bool if ty == 'bool'

    if ty.is_a?(String)
      ty
    else
      # bitmasks need a Flags suffix so we use the flag type
      is_bitmask = types[:bitmasks].has_key?(ty) && types[:bitmasks][ty].is_a?(TypeBitmask)
      suffix = if is_bitmask then ; 'Flags' else ''; end
      "#{to_n(ty)}#{suffix}"
    end
  end
end


###
### Main ###
###
data = File.open('webgpu.xml').read
doc = REXML::Document.new(data)
webgpu = REXML::XPath.first(doc, '//webgpu')

# Gather all of the data from the XML file
license = text_of_first(webgpu, 'license')
prefix = text_of_first(webgpu, 'metadata/prefix/c')
defines = gather_defines(REXML::XPath.first(webgpu, 'defines'))
types = gather_types(REXML::XPath.first(webgpu, 'types'))
functions = gather_functions(webgpu)
objects = gather_objects(REXML::XPath.first(webgpu, 'objects'))

# Generate the webgpu.h header
formatter = FormatCHeader.new(license, prefix, defines, types, functions, objects)
puts formatter.to_s
