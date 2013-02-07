
# pull in external modules
util = require './util'
ConstantPool = require './ConstantPool'
attributes = require './attributes'
opcodes = require './opcodes'
methods = require './methods'
types = require './types'
{java_throw} = require './exceptions'
{c2t} = types
{trace} = require './logging'
{JavaClassObject} = require './java_object'

"use strict"

class ClassFile
  constructor: (bytes_array, @loader=null) ->
    bytes_array = new util.BytesArray bytes_array
    throw "Magic number invalid" if (bytes_array.get_uint 4) != 0xCAFEBABE
    @minor_version = bytes_array.get_uint 2
    @major_version = bytes_array.get_uint 2
    throw "Major version invalid" unless 45 <= @major_version <= 51
    @constant_pool = new ConstantPool
    @constant_pool.parse(bytes_array)
    # bitmask for {public,final,super,interface,abstract} class modifier
    @access_byte = bytes_array.get_uint 2
    @access_flags = util.parse_flags @access_byte
    @this_class  = c2t(@constant_pool.get(bytes_array.get_uint 2).deref())
    # super reference is 0 when there's no super (basically just java.lang.Object)
    super_ref = bytes_array.get_uint 2
    @super_class = c2t(@constant_pool.get(super_ref).deref()) unless super_ref is 0
    # direct interfaces of this class
    isize = bytes_array.get_uint 2
    @interfaces = (bytes_array.get_uint 2 for i in [0...isize] by 1)
    # fields of this class
    num_fields = bytes_array.get_uint 2
    @fields = (new methods.Field(@, @this_class) for i in [0...num_fields] by 1)
    @fl_cache = {}

    for f,i in @fields
      f.parse(bytes_array,@constant_pool,i)
      @fl_cache[f.name] = f
    # class methods
    num_methods = bytes_array.get_uint 2
    @methods = {}
    # It would probably be safe to make @methods the @ml_cache, but it would
    # make debugging harder as you would lose track of who owns what method.
    @ml_cache = {}
    for i in [0...num_methods] by 1
      m = new methods.Method(@, @this_class)
      m.parse(bytes_array,@constant_pool,i)
      mkey = m.name + m.raw_descriptor
      @methods[mkey] = m
      @ml_cache[mkey] = m
    # class attributes
    @attrs = attributes.make_attributes(bytes_array,@constant_pool)
    throw "Leftover bytes in classfile: #{bytes_array}" if bytes_array.has_bytes()

    @jco = null
    @initialized = false # Has clinit been run?
    # Contains the value of all static fields. Will be reset when initialize()
    # is run.
    @static_fields = @_construct_static_fields()

  @for_array_type: (type, @loader=null) ->
    class_file = Object.create ClassFile.prototype # avoid calling the constructor
    class_file.constant_pool = new ConstantPool
    class_file.ml_cache = {}
    class_file.fl_cache = {}
    class_file.access_flags = {}
    class_file.this_class = type
    class_file.super_class = c2t('java/lang/Object')
    class_file.interfaces = []
    class_file.fields = []
    class_file.methods = {}
    class_file.attrs = []
    class_file.initialized = false
    class_file.static_fields = []
    class_file

  # XXX: Used instead of PrimitiveTypes. Created so is_castable / check_cast
  # can operate on ClassFiles rather than type objects.
  # We should probably morph this into a formal hierarchy. And rename ClassFile
  # to something more representative of its functionality.
  @for_primitive: (type, @loader=null) ->
    class_file = Object.create ClassFile.prototype # avoid calling the constructor
    class_file.constant_pool = new ConstantPool
    class_file.ml_cache = {}
    class_file.fl_cache = {}
    class_file.access_flags = {}
    class_file.this_class = type
    class_file.super_class = null
    class_file.interfaces = []
    class_file.fields = []
    class_file.methods = {}
    class_file.attrs = []
    class_file.initialized = true
    class_file.static_fields = []
    class_file

  # Proxy method for type's method until we get rid of type objects.
  toClassString: () -> @this_class.toClassString()
  toExternalString: () -> @this_class.toExternalString()

  # We should use this instead of the above. Returns the standardized type
  # string for this class, whether it be a Reference or a Primitive type.
  toTypeString: () ->
    if @this_class instanceof types.PrimitiveType then @toExternalString() else @toClassString()

  get_class_object: (rs) -> if @jco? then @jco else @jco = new JavaClassObject rs, @

  # Spec [5.4.3.2][1].
  # [1]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/ConstantPool.doc.html#77678
  field_lookup: (rs, field_spec) ->
    unless @fl_cache[field_spec.name]?
      @fl_cache[field_spec.name] = @_field_lookup(rs, field_spec)
    return @fl_cache[field_spec.name]

  _field_lookup: (rs, field_spec) ->
    for field in @fields
      if field.name is field_spec.name
        return field

    # These may not be initialized! But we have them loaded.
    for i in @interfaces
      ifc_cls = rs.get_loaded_class c2t @constant_pool.get(i).deref()
      field = ifc_cls.field_lookup(rs, field_spec)
      return field if field?

    if @super_class?
      sc = rs.class_lookup @super_class
      field = sc.field_lookup(rs, field_spec)
      return field if field?
    return null

  # Spec [5.4.3.3][1], [5.4.3.4][2].
  # [1]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/ConstantPool.doc.html#79473
  # [2]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/ConstantPool.doc.html#78621
  method_lookup: (rs, method_spec) ->
    unless @ml_cache[method_spec.sig]?
      @ml_cache[method_spec.sig] = @_method_lookup(rs, method_spec)
    return @ml_cache[method_spec.sig]

  _method_lookup: (rs, method_spec) ->
    method = @methods[method_spec.sig]
    return method if method?

    if @super_class?
      parent = rs.class_lookup @super_class
      method = parent.method_lookup(rs, method_spec)
      return method if method?

    for i in @interfaces
      ifc = rs.get_loaded_class c2t @constant_pool.get(i).deref()
      method = ifc.method_lookup(rs, method_spec)
      return method if method?

    return null

  static_get: (rs, name) ->
    return @static_fields[name] unless @static_fields[name] is undefined
    java_throw rs, rs.class_lookup(c2t 'java/lang/NoSuchFieldError'), name

  static_put: (rs, name, val) ->
    unless @static_fields[name] is undefined
      @static_fields[name] = val
    else
      java_throw rs, rs.class_lookup(c2t 'java/lang/NoSuchFieldError'), name

  # Resets any ClassFile state that may have been built up
  load: () ->
    @initialized = false
    @jco = null

  # "Reinitializes" the ClassFile for subsequent JVM invocations. Resets all
  # of the built up state / caches present in the opcode instructions.
  # Eventually, this will also handle `clinit` duties.
  initialize: () ->
    unless @initialized
      @static_fields = @_construct_static_fields()
      for method in @methods
        method.initialize()

  construct_default_fields: (rs) ->
    # init fields from this and inherited ClassFiles
    t = @this_class
    # Object.create(null) avoids interference with Object.prototype's properties
    @default_fields = Object.create null
    while t?
      cls = rs.class_lookup t
      for f in cls.fields when not f.access_flags.static
        val = util.initial_value f.raw_descriptor
        @default_fields[t.toClassString() + '/' + f.name] = val
      t = cls.super_class

  # Used internally to reconstruct @static_fields
  _construct_static_fields: ->
    static_fields = Object.create null
    for f in @fields when f.access_flags.static
      static_fields[f.name] = util.initial_value f.raw_descriptor
    return static_fields

  get_default_fields: (rs) ->
    return @default_fields unless @default_fields is undefined
    @construct_default_fields(rs)
    return @default_fields

  # Checks if the class file is initialized. It will set @initialized to 'true'
  # if this class has no static initialization method and its parent classes
  # are initialized, too.
  is_initialized: (rs) ->
    return true if @initialized
    # XXX: Hack to avoid traversing hierarchy.
    return false if @methods['<clinit>()V']?
    @initialized = if @super_class? then rs.class_lookup(@super_class, @, true)?.is_initialized(rs) else false
    return @initialized

  # Returns the JavaObject object of the classloader that initialized this
  # class. Returns null for the default classloader.
  get_class_loader: () -> return @loader
  # Returns the unique ID of this class loader. Returns null for the bootstrap
  # classloader.
  get_class_loader_id: () -> if @loader? then return @loader.ref else return null

if module?
  module.exports = ClassFile
else
  window.ClassFile = ClassFile
