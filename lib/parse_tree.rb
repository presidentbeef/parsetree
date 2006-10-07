#!/usr/local/bin/ruby -w

begin require 'rubygems'; rescue LoadError; end

require 'inline'

##
# ParseTree is a RubyInline-style extension that accesses and
# traverses the internal parse tree created by ruby.
#
#   class Example
#     def blah
#       return 1 + 1
#     end
#   end
#
#   ParseTree.new.parse_tree(Example)
#   => [[:class, :Example, :Object,
#          [:defn,
#            "blah",
#            [:scope,
#              [:block,
#                [:args],
#                [:return, [:call, [:lit, 1], "+", [:array, [:lit, 1]]]]]]]]]

class ParseTree

  VERSION = '1.5.0'

  ##
  # Initializes a ParseTree instance. Includes newline nodes if
  # +include_newlines+ which defaults to +$DEBUG+.

  def initialize(include_newlines=$DEBUG)
    if include_newlines then
      warn "WARNING: include_newlines=true from #{caller[0..9].join(', ')}"
    end
    @include_newlines = include_newlines
  end

  ##
  # Main driver for ParseTree. Returns an array of arrays containing
  # the parse tree for +klasses+.
  #
  # Structure:
  #
  #   [[:class, classname, superclassname, [:defn :method1, ...], ...], ...]
  #
  # NOTE: v1.0 - v1.1 had the signature (klass, meth=nil). This wasn't
  # used much at all and since parse_tree_for_method already existed,
  # it was deemed more useful to expand this method to do multiple
  # classes.

  def parse_tree(*klasses)
    result = []
    klasses.each do |klass|
      # TODO: remove this on v 1.1
      raise "You should call parse_tree_for_method(#{klasses.first}, #{klass}) instead of parse_tree" if Symbol === klass or String === klass
      klassname = klass.name rescue '' # HACK klass.name should never be nil
                                   # Tempfile's DelegateClass(File) seems to
                                   # cause this
      klassname = "UnnamedClass_#{klass.object_id}" if klassname.empty?
      klassname = klassname.to_sym

      code = if Class === klass then
               sc = klass.superclass
               sc_name = ((sc.nil? or sc.name.empty?) ? "nil" : sc.name).intern
               [:class, klassname, sc_name]
             else
               [:module, klassname]
             end

      method_names = []
      method_names += klass.instance_methods false
      method_names += klass.private_instance_methods false
      # protected methods are included in instance_methods, go figure!

      method_names.sort.each do |m|
        code << parse_tree_for_method(klass, m.to_sym)
      end

      klass.singleton_methods.sort.each do |m|
        code << parse_tree_for_method(klass, m.to_sym, true)
      end

      result << code
    end
    return result
  end

  ##
  # Returns the parse tree for just one +method+ of a class +klass+.
  #
  # Format:
  #
  #   [:defn, :name, :body]

  def parse_tree_for_method(klass, method, is_cls_meth=false)
    $stderr.puts "** parse_tree_for_method(#{klass}, #{method}):" if $DEBUG
    r = parse_tree_for_meth(klass, method.to_sym, @include_newlines, is_cls_meth)
    r[1] = :"self.#{r[1]}" if is_cls_meth
    r
  end

  ##
  # Returns the parse tree for a string +source+.
  #
  # Format:
  #
  #   [[sexps] ... ]

  def parse_tree_for_string(source, filename = nil, line = nil,
                            newlines = false)
    filename ||= '(string)'
    line ||= 1
    return parse_tree_for_str(source, filename, line, newlines)
  end

  if RUBY_VERSION < "1.8.4" then
    inline do |builder|
      builder.add_type_converter("bool", '', '')
      builder.c_singleton "
        bool has_alloca() {
          (void)self;
          #ifdef C_ALLOCA
            return Qtrue;
          #else
            return Qfalse;
          #endif
          }"
    end
  else
    def self.has_alloca
      true
    end
  end


  NODE_NAMES = [
                #  00
                :method, :fbody, :cfunc, :scope, :block,
                :if, :case, :when, :opt_n, :while,
                #  10
                :until, :iter, :for, :break, :next,
                :redo, :retry, :begin, :rescue, :resbody,
                #  20
                :ensure, :and, :or, :not, :masgn,
                :lasgn, :dasgn, :dasgn_curr, :gasgn, :iasgn,
                #  30
                :cdecl, :cvasgn, :cvdecl, :op_asgn1, :op_asgn2,
                :op_asgn_and, :op_asgn_or, :call, :fcall, :vcall,
                #  40
                :super, :zsuper, :array, :zarray, :hash,
                :return, :yield, :lvar, :dvar, :gvar,
                #  50
                :ivar, :const, :cvar, :nth_ref, :back_ref,
                :match, :match2, :match3, :lit, :str,
                #  60
                :dstr, :xstr, :dxstr, :evstr, :dregx,
                :dregx_once, :args, :argscat, :argspush, :splat,
                #  70
                :to_ary, :svalue, :block_arg, :block_pass, :defn,
                :defs, :alias, :valias, :undef, :class,
                #  80
                :module, :sclass, :colon2, :colon3, :cref,
                :dot2, :dot3, :flip2, :flip3, :attrset,
                #  90
                :self, :nil, :true, :false, :defined,
                #  95
                :newline, :postexe, :alloca, :dmethod, :bmethod,
                # 100
                :memo, :ifunc, :dsym, :attrasgn,
                :last
               ]

  if RUBY_VERSION < "1.8.4" then
    NODE_NAMES.delete :alloca unless has_alloca
  end

  if RUBY_VERSION > "1.9" then
    NODE_NAMES.insert NODE_NAMES.index(:hash), :values
    NODE_NAMES.insert NODE_NAMES.index(:defined), :errinfo
    NODE_NAMES.insert NODE_NAMES.index(:last), :prelude, :lambda
    NODE_NAMES.delete :dmethod
    NODE_NAMES[128] = NODE_NAMES.delete :newline
  end

  ############################################################
  # END of rdoc methods
  ############################################################

  inline do |builder|
    builder.add_type_converter("bool", '', '')
    builder.add_type_converter("ID *", '', '')
    builder.add_type_converter("NODE *", '(NODE *)', '(VALUE)')
    builder.include '"intern.h"'
    builder.include '"version.h"'
    builder.include '"rubysig.h"'
    builder.include '"node.h"'
    builder.include '"st.h"'
    builder.include '"env.h"'
    builder.add_compile_flags "-Wall"
    builder.add_compile_flags "-W"
    builder.add_compile_flags "-Wpointer-arith"
    builder.add_compile_flags "-Wcast-qual"
    builder.add_compile_flags "-Wcast-align"
    builder.add_compile_flags "-Wwrite-strings"
    builder.add_compile_flags "-Wmissing-noreturn"
    # NOTE: If you get weird compiler errors like:
    #    dereferencing type-punned pointer will break strict-aliasing rules
    # PLEASE do one of the following:
    # 1) Get me a login on your box so I can repro this and get it fixed.
    # 2) Fix it and send me the patch
    # 3) (quick, but dirty and bad), comment out the following line:
    builder.add_compile_flags "-Werror"
    # NOTE: this flag doesn't work w/ gcc 2.95.x - the FreeBSD default
    # builder.add_compile_flags "-Wno-strict-aliasing"
    # ruby.h screws these up hardcore:
    # builder.add_compile_flags "-Wundef"
    # builder.add_compile_flags "-Wconversion"
    # builder.add_compile_flags "-Wstrict-prototypes"
    # builder.add_compile_flags "-Wmissing-prototypes"
    # builder.add_compile_flags "-Wsign-compare"

    def self.if_version(test, version, str)
      RUBY_VERSION.send(test, version) ? str : ""
    end

    builder.prefix %{
        #define nd_3rd   u3.node
    }

    builder.prefix %{
        struct METHOD {
          VALUE klass, rklass;
          VALUE recv;
          ID id, oid;
#{if_version :>, "1.8.2", "int safe_level;"}
          NODE *body;
        };

        struct BLOCK {
          NODE *var;
          NODE *body;
          VALUE self;
          struct FRAME frame;
          struct SCOPE *scope;
          VALUE klass;
          NODE *cref;
          int iter;
          int vmode;
          int flags;
          int uniq;
          struct RVarmap *dyna_vars;
          VALUE orig_thread;
          VALUE wrapper;
          VALUE block_obj;
          struct BLOCK *outer;
          struct BLOCK *prev;
        };
    } unless RUBY_VERSION >= "1.9" # we got matz to add this to env.h

  ##
  # add_to_parse_tree(ary, node, include_newlines, local_variables)

  builder.c_raw %Q@
static void add_to_parse_tree(VALUE ary,
                              NODE * n,
                              VALUE newlines,
                              ID * locals) {
  NODE * volatile node = n;
  NODE * volatile contnode = NULL;
  VALUE old_ary = Qnil;
  VALUE current;
  VALUE node_name;
  static VALUE node_names = Qnil;

  if (NIL_P(node_names)) {
    node_names = rb_const_get_at(rb_const_get_at(rb_cObject,rb_intern("ParseTree")),rb_intern("NODE_NAMES"));
  }

  if (!node) return;

again:

  if (node) {
    node_name = rb_ary_entry(node_names, nd_type(node));
    if (RTEST(ruby_debug)) {
      fprintf(stderr, "%15s: %s%s%s\\n",
        rb_id2name(SYM2ID(node_name)),
        (RNODE(node)->u1.node != NULL ? "u1 " : "   "),
        (RNODE(node)->u2.node != NULL ? "u2 " : "   "),
        (RNODE(node)->u3.node != NULL ? "u3 " : "   "));
    }
  } else {
    node_name = ID2SYM(rb_intern("ICKY"));
  }

  current = rb_ary_new();
  rb_ary_push(ary, current);
  rb_ary_push(current, node_name);

again_no_block:

    switch (nd_type(node)) {

    case NODE_BLOCK:
      if (contnode) {
        add_to_parse_tree(current, node, newlines, locals);
        break;
      }
      contnode = node->nd_next;

      // NOTE: this will break the moment there is a block w/in a block
      old_ary = ary;
      ary = current;
      node = node->nd_head;
      goto again;
      break;

    case NODE_FBODY:
    case NODE_DEFINED:
      add_to_parse_tree(current, node->nd_head, newlines, locals);
      break;

    case NODE_COLON2:
      add_to_parse_tree(current, node->nd_head, newlines, locals);
      rb_ary_push(current, ID2SYM(node->nd_mid));
      break;

    case NODE_MATCH2:
    case NODE_MATCH3:
      add_to_parse_tree(current, node->nd_recv, newlines, locals);
      add_to_parse_tree(current, node->nd_value, newlines, locals);
      break;

    case NODE_BEGIN:
    case NODE_OPT_N:
    case NODE_NOT:
      add_to_parse_tree(current, node->nd_body, newlines, locals);
      break;

    case NODE_IF:
      add_to_parse_tree(current, node->nd_cond, newlines, locals);
      if (node->nd_body) {
        add_to_parse_tree(current, node->nd_body, newlines, locals);
      } else {
        rb_ary_push(current, Qnil);
      }
      if (node->nd_else) {
        add_to_parse_tree(current, node->nd_else, newlines, locals);
      } else {
        rb_ary_push(current, Qnil);
      }
      break;

  case NODE_CASE:
    add_to_parse_tree(current, node->nd_head, newlines, locals); /* expr */
    node = node->nd_body;
    while (node) {
      add_to_parse_tree(current, node, newlines, locals);
      if (nd_type(node) == NODE_WHEN) {                 /* when */
        node = node->nd_next; 
      } else {
        break;                                          /* else */
      }
      if (! node) {
        rb_ary_push(current, Qnil);                     /* no else */
      }
    }
    break;

  case NODE_WHEN:
    add_to_parse_tree(current, node->nd_head, newlines, locals); /* args */
    if (node->nd_body) {
      add_to_parse_tree(current, node->nd_body, newlines, locals); /* body */
    } else {
      rb_ary_push(current, Qnil);
    }
    break;

  case NODE_WHILE:
  case NODE_UNTIL:
    add_to_parse_tree(current,  node->nd_cond, newlines, locals);
    add_to_parse_tree(current,  node->nd_body, newlines, locals); 
    rb_ary_push(current, node->nd_3rd == 0 ? Qfalse : Qtrue);
    break;

  case NODE_BLOCK_PASS:
    add_to_parse_tree(current, node->nd_body, newlines, locals);
    add_to_parse_tree(current, node->nd_iter, newlines, locals);
    break;

  case NODE_ITER:
  case NODE_FOR:
    add_to_parse_tree(current, node->nd_iter, newlines, locals);
    if (node->nd_var != (NODE *)1
        && node->nd_var != (NODE *)2
        && node->nd_var != NULL) {
      add_to_parse_tree(current, node->nd_var, newlines, locals);
    } else {
      rb_ary_push(current, Qnil);
    }
    add_to_parse_tree(current, node->nd_body, newlines, locals);
    break;

  case NODE_BREAK:
  case NODE_NEXT:
  case NODE_YIELD:
    if (node->nd_stts)
      add_to_parse_tree(current, node->nd_stts, newlines, locals);
    break;

  case NODE_RESCUE:
      add_to_parse_tree(current, node->nd_1st, newlines, locals);
      add_to_parse_tree(current, node->nd_2nd, newlines, locals);
      add_to_parse_tree(current, node->nd_3rd, newlines, locals);
    break;

  // rescue body:
  // begin stmt rescue exception => var; stmt; [rescue e2 => v2; s2;]* end 
  // stmt rescue stmt
  // a = b rescue c

  case NODE_RESBODY:
      if (node->nd_3rd) {
        add_to_parse_tree(current, node->nd_3rd, newlines, locals);
      } else {
        rb_ary_push(current, Qnil);
      }
      add_to_parse_tree(current, node->nd_2nd, newlines, locals);
      add_to_parse_tree(current, node->nd_1st, newlines, locals);
    break;
	
  case NODE_ENSURE:
    add_to_parse_tree(current, node->nd_head, newlines, locals);
    if (node->nd_ensr) {
      add_to_parse_tree(current, node->nd_ensr, newlines, locals);
    }
    break;

  case NODE_AND:
  case NODE_OR:
    add_to_parse_tree(current, node->nd_1st, newlines, locals);
    add_to_parse_tree(current, node->nd_2nd, newlines, locals);
    break;

  case NODE_DOT2:
  case NODE_DOT3:
  case NODE_FLIP2:
  case NODE_FLIP3:
    add_to_parse_tree(current, node->nd_beg, newlines, locals);
    add_to_parse_tree(current, node->nd_end, newlines, locals);
    break;

  case NODE_RETURN:
    if (node->nd_stts)
      add_to_parse_tree(current, node->nd_stts, newlines, locals);
    break;

  case NODE_ARGSCAT:
  case NODE_ARGSPUSH:
    add_to_parse_tree(current, node->nd_head, newlines, locals);
    add_to_parse_tree(current, node->nd_body, newlines, locals);
    break;

  case NODE_CALL:
  case NODE_FCALL:
  case NODE_VCALL:
    if (nd_type(node) != NODE_FCALL)
      add_to_parse_tree(current, node->nd_recv, newlines, locals);
    rb_ary_push(current, ID2SYM(node->nd_mid));
    if (node->nd_args || nd_type(node) != NODE_FCALL)
      add_to_parse_tree(current, node->nd_args, newlines, locals);
    break;

  case NODE_SUPER:
    add_to_parse_tree(current, node->nd_args, newlines, locals);
    break;

  case NODE_BMETHOD:
    {
      struct BLOCK *data;
      Data_Get_Struct(node->nd_cval, struct BLOCK, data);
      add_to_parse_tree(current, data->var, newlines, locals);
      add_to_parse_tree(current, data->body, newlines, locals);
      break;
    }
    break;

#{if_version :>, "1.9", '#if 0'}
  case NODE_DMETHOD:
    {
      struct METHOD *data;
      Data_Get_Struct(node->nd_cval, struct METHOD, data);
      rb_ary_push(current, ID2SYM(data->id));
      add_to_parse_tree(current, data->body, newlines, locals);
      break;
    }
#{if_version :>, "1.9", '#endif'}

  case NODE_METHOD:
    fprintf(stderr, "u1 = %p u2 = %p u3 = %p\\n", node->nd_1st, node->nd_2nd, node->nd_3rd);
    add_to_parse_tree(current, node->nd_3rd, newlines, locals);
    break;

  case NODE_SCOPE:
    add_to_parse_tree(current, node->nd_next, newlines, node->nd_tbl);
    break;

  case NODE_OP_ASGN1:
    add_to_parse_tree(current, node->nd_recv, newlines, locals);
    add_to_parse_tree(current, node->nd_args->nd_2nd, newlines, locals);
    switch (node->nd_mid) {
    case 0:
      rb_ary_push(current, ID2SYM(rb_intern("||")));
      break;
    case 1:
      rb_ary_push(current, ID2SYM(rb_intern("&&")));
      break;
    default:
      rb_ary_push(current, ID2SYM(node->nd_mid));
      break;
    }
    add_to_parse_tree(current, node->nd_args->nd_head, newlines, locals);
    break;

  case NODE_OP_ASGN2:
    add_to_parse_tree(current, node->nd_recv, newlines, locals);
    rb_ary_push(current, ID2SYM(node->nd_next->nd_aid));

    switch (node->nd_next->nd_mid) {
    case 0:
      rb_ary_push(current, ID2SYM(rb_intern("||")));
      break;
    case 1:
      rb_ary_push(current, ID2SYM(rb_intern("&&")));
      break;
    default:
      rb_ary_push(current, ID2SYM(node->nd_next->nd_mid));
      break;
    }

    add_to_parse_tree(current, node->nd_value, newlines, locals);
    break;

  case NODE_OP_ASGN_AND:
  case NODE_OP_ASGN_OR:
    add_to_parse_tree(current, node->nd_head, newlines, locals);
    add_to_parse_tree(current, node->nd_value, newlines, locals);
    break;

  case NODE_MASGN:
    add_to_parse_tree(current, node->nd_head, newlines, locals);
    if (node->nd_args) {
      if (node->nd_args != (NODE *)-1) {
	add_to_parse_tree(current, node->nd_args, newlines, locals);
      }
    }
    add_to_parse_tree(current, node->nd_value, newlines, locals);
    break;

  case NODE_LASGN:
  case NODE_IASGN:
  case NODE_DASGN:
  case NODE_DASGN_CURR:
  case NODE_CDECL:
  case NODE_CVASGN:
  case NODE_CVDECL:
  case NODE_GASGN:
    rb_ary_push(current, ID2SYM(node->nd_vid));
    add_to_parse_tree(current, node->nd_value, newlines, locals);
    break;

  case NODE_ALIAS:            // u1 u2 (alias :blah :blah2)
  case NODE_VALIAS:           // u1 u2 (alias $global $global2)
    rb_ary_push(current, ID2SYM(node->u1.id));
    rb_ary_push(current, ID2SYM(node->u2.id));
    break;

  case NODE_COLON3:           // u2    (::OUTER_CONST)
  case NODE_UNDEF:            // u2    (undef instvar)
    rb_ary_push(current, ID2SYM(node->u2.id));
    break;

  case NODE_HASH:
    {
      NODE *list;
	
      list = node->nd_head;
      while (list) {
	add_to_parse_tree(current, list->nd_head, newlines, locals);
	list = list->nd_next;
	if (list == 0)
	  rb_bug("odd number list for Hash");
	add_to_parse_tree(current, list->nd_head, newlines, locals);
	list = list->nd_next;
      }
    }
    break;

  case NODE_ARRAY:
      while (node) {
	add_to_parse_tree(current, node->nd_head, newlines, locals);
        node = node->nd_next;
      }
    break;

  case NODE_DSTR:
  case NODE_DSYM:
  case NODE_DXSTR:
  case NODE_DREGX:
  case NODE_DREGX_ONCE:
    {
      NODE *list = node->nd_next;
      if (nd_type(node) == NODE_DREGX || nd_type(node) == NODE_DREGX_ONCE) {
	break;
      }
      rb_ary_push(current, rb_str_new3(node->nd_lit));
      while (list) {
	if (list->nd_head) {
	  switch (nd_type(list->nd_head)) {
	  case NODE_STR:
	    add_to_parse_tree(current, list->nd_head, newlines, locals);
	    break;
	  case NODE_EVSTR:
	    add_to_parse_tree(current, list->nd_head->nd_body, newlines, locals);
	    break;
	  default:
	    add_to_parse_tree(current, list->nd_head, newlines, locals);
	    break;
	  }
	}
	list = list->nd_next;
      }
    }
    break;

  case NODE_DEFN:
  case NODE_DEFS:
    if (node->nd_defn) {
      if (nd_type(node) == NODE_DEFS)
	add_to_parse_tree(current, node->nd_recv, newlines, locals);
      rb_ary_push(current, ID2SYM(node->nd_mid));
      add_to_parse_tree(current, node->nd_defn, newlines, locals);
    }
    break;

  case NODE_CLASS:
  case NODE_MODULE:
    rb_ary_push(current, ID2SYM((ID)node->nd_cpath->nd_mid));
    if (node->nd_super && nd_type(node) == NODE_CLASS) {
      add_to_parse_tree(current, node->nd_super, newlines, locals);
    }
    add_to_parse_tree(current, node->nd_body, newlines, locals);
    break;

  case NODE_SCLASS:
    add_to_parse_tree(current, node->nd_recv, newlines, locals);
    add_to_parse_tree(current, node->nd_body, newlines, locals);
    break;

  case NODE_ARGS: {
    long arg_count = (long)node->nd_rest;
    if (locals && (node->nd_cnt || node->nd_opt || arg_count != -1)) {
      int i;
      int max_args;
      NODE *optnode;

      max_args = node->nd_cnt;
      for (i = 0; i < max_args; i++) {
        // regular arg names
        rb_ary_push(current, ID2SYM(locals[i + 3]));
      }

      optnode = node->nd_opt;
      while (optnode) {
        // optional arg names
        rb_ary_push(current, ID2SYM(locals[i + 3]));
	i++;
	optnode = optnode->nd_next;
      }

      if (arg_count > 0) {
        // *arg name
        VALUE sym = rb_str_intern(rb_str_plus(rb_str_new2("*"), rb_str_new2(rb_id2name(locals[i + 3]))));
        rb_ary_push(current, sym);
      } else if (arg_count == 0) {
        // nothing to do in this case, empty list
      } else if (arg_count == -1) {
        // nothing to do in this case, handled above
      } else if (arg_count == -2) {
        // nothing to do in this case, no name == no use
      } else {
        rb_raise(rb_eArgError,
                 "not a clue what this arg value is: %ld", arg_count);
      }

      optnode = node->nd_opt;
      // block?
      if (optnode) {
	add_to_parse_tree(current, node->nd_opt, newlines, locals);
      }
    }
  }  break;
	
  case NODE_LVAR:
  case NODE_DVAR:
  case NODE_IVAR:
  case NODE_CVAR:
  case NODE_GVAR:
  case NODE_CONST:
  case NODE_ATTRSET:
    rb_ary_push(current, ID2SYM(node->nd_vid));
    break;

  case NODE_XSTR:             // u1    (%x{ls})
  case NODE_STR:              // u1
  case NODE_LIT:
  case NODE_MATCH:
    rb_ary_push(current, node->nd_lit);
    break;

  case NODE_NEWLINE:
    rb_ary_push(current, INT2FIX(nd_line(node)));
    rb_ary_push(current, rb_str_new2(node->nd_file));

    if (! RTEST(newlines)) rb_ary_pop(ary); // nuke it

    node = node->nd_next;
    goto again;
    break;

  case NODE_NTH_REF:          // u2 u3 ($1) - u3 is local_cnt('~') ignorable?
    rb_ary_push(current, INT2FIX(node->nd_nth));
    break;

  case NODE_BACK_REF:         // u2 u3 ($& etc)
    {
    char c = node->nd_nth;
    rb_ary_push(current, rb_str_intern(rb_str_new(&c, 1)));
    }
    break;

  case NODE_BLOCK_ARG:        // u1 u3 (def x(&b)
    rb_ary_push(current, ID2SYM(node->u1.id));
    break;

  // these nodes are empty and do not require extra work:
  case NODE_RETRY:
  case NODE_FALSE:
  case NODE_NIL:
  case NODE_SELF:
  case NODE_TRUE:
  case NODE_ZARRAY:
  case NODE_ZSUPER:
  case NODE_REDO:
    break;

  case NODE_SPLAT:
  case NODE_TO_ARY:
  case NODE_SVALUE:             // a = b, c
    add_to_parse_tree(current, node->nd_head, newlines, locals);
    break;

  case NODE_ATTRASGN:           // literal.meth = y u1 u2 u3
    // node id node
    if (node->nd_1st == RNODE(1)) {
      add_to_parse_tree(current, NEW_SELF(), newlines, locals);
    } else {
      add_to_parse_tree(current, node->nd_1st, newlines, locals);
    }
    rb_ary_push(current, ID2SYM(node->u2.id));
    add_to_parse_tree(current, node->nd_3rd, newlines, locals);
    break;

  case NODE_EVSTR:
    add_to_parse_tree(current, node->nd_2nd, newlines, locals);
    break;

  case NODE_POSTEXE:            // END { ... }
    // Nothing to do here... we are in an iter block
    break;

  case NODE_CFUNC:
    rb_ary_push(current, INT2FIX(node->nd_cfnc));
    rb_ary_push(current, INT2FIX(node->nd_argc));
    break;

#{if_version :<, "1.9", "#if 0"}
  case NODE_ERRINFO:
  case NODE_VALUES:
  case NODE_PRELUDE:
  case NODE_LAMBDA:
    puts("no worky in 1.9 yet");
    break;
#{if_version :<, "1.9", "#endif"}

  // Nodes we found but have yet to decypher
  // I think these are all runtime only... not positive but...
  case NODE_MEMO:               // enum.c zip
  case NODE_CREF:
  case NODE_IFUNC:
  // #defines:
  // case NODE_LMASK:
  // case NODE_LSHIFT:
  default:
    rb_warn("Unhandled node #%d type '%s'", nd_type(node), rb_id2name(SYM2ID(rb_ary_entry(node_names, nd_type(node)))));
    if (RNODE(node)->u1.node != NULL) rb_warning("unhandled u1 value");
    if (RNODE(node)->u2.node != NULL) rb_warning("unhandled u2 value");
    if (RNODE(node)->u3.node != NULL) rb_warning("unhandled u3 value");
    if (RTEST(ruby_debug)) fprintf(stderr, "u1 = %p u2 = %p u3 = %p\\n", node->nd_1st, node->nd_2nd, node->nd_3rd);
    rb_ary_push(current, INT2FIX(-99));
    rb_ary_push(current, INT2FIX(nd_type(node)));
    break;
  }

 //  finish:
  if (contnode) {
      node = contnode;
      contnode = NULL;
      current = ary;
      ary = old_ary;
      old_ary = Qnil;
      goto again_no_block;
  }
}
@ # end of add_to_parse_tree block

    builder.c %Q{
static VALUE parse_tree_for_meth(VALUE klass, VALUE method, VALUE newlines, VALUE is_cls_meth) {
  VALUE n;
  NODE *node = NULL;
  ID id;
  VALUE result = rb_ary_new();

  (void) self; // quell warnings

  VALUE version = rb_const_get_at(rb_cObject,rb_intern("RUBY_VERSION"));
  if (strcmp(StringValuePtr(version), #{RUBY_VERSION.inspect})) {
    rb_fatal("bad version, %s != #{RUBY_VERSION}\\n", StringValuePtr(version));
  }

  id = rb_to_id(method);
  if (RTEST(is_cls_meth)) { // singleton method
    klass = CLASS_OF(klass);
  }
  if (st_lookup(RCLASS(klass)->m_tbl, id, &n)) {
    node = (NODE*)n;
    rb_ary_push(result, ID2SYM(rb_intern("defn")));
    rb_ary_push(result, ID2SYM(id));
    add_to_parse_tree(result, node->nd_body, newlines, NULL);
  } else {
    rb_ary_push(result, Qnil);
  }

  return result;
}
}

    builder.prefix " extern NODE *ruby_eval_tree_begin; " \
      if RUBY_VERSION < '1.9.0'

    builder.c %Q{
static VALUE parse_tree_for_str(VALUE source, VALUE filename, VALUE line,
                                   VALUE newlines) {
  VALUE tmp;
  VALUE result = rb_ary_new();
  NODE *node = NULL;
  int critical;

  (void) self; // quell warnings

  tmp = rb_check_string_type(filename);
  if (NIL_P(tmp)) {
    filename = rb_str_new2("(string)");
  }

  if (NIL_P(line)) {
    line = LONG2FIX(1);
  }

  newlines = RTEST(newlines);

  ruby_nerrs = 0;
  StringValue(source);
  critical = rb_thread_critical;
  rb_thread_critical = Qtrue;
  ruby_in_eval++;
  node = rb_compile_string(StringValuePtr(filename), source, NUM2INT(line));
  ruby_in_eval--;
  rb_thread_critical = critical;

  if (ruby_nerrs > 0) {
    ruby_nerrs = 0;
#if RUBY_VERSION_CODE < 190
    ruby_eval_tree_begin = 0;
#endif
    rb_exc_raise(ruby_errinfo);
  }

  add_to_parse_tree(result, node, newlines, NULL);

  return result;
}
}

  end # inline call
end # ParseTree class
