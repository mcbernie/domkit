package domkit;
#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import domkit.Error;
using haxe.macro.Tools;
#end

class Macros {
	#if macro

	@:persistent static var COMPONENTS = new Map<String, domkit.MetaComponent>();
	@:persistent static var componentsSearchPath : Array<String> = ["h2d.domkit.BaseComponents.$Comp"];
	@:persistent static var componentsType : ComplexType;
	static var RESOLVED_COMPONENTS = new Map();

	public static dynamic function customTextParser( id : String, args : Null<Array<haxe.macro.Expr>>, pos : haxe.macro.Expr.Position ) : haxe.macro.Expr {
		return null;
	}

	public static function registerComponentsPath( path : String ) {
		if( componentsSearchPath.indexOf(path) < 0 )
			componentsSearchPath.push(path);
	}

	static function loadComponent( name : String, pmin : Int, pmax : Int ) {
		var c = RESOLVED_COMPONENTS.get(name);
		if( c != null ) {
			Context.getType(c.path);
			return c.c;
		}
		var lastError = null;
		var uname = name.charAt(0).toUpperCase()+name.substr(1);
		for( p in componentsSearchPath ) {
			var path = p.split("$").join(uname);
			var t = try Context.getType(path) catch( e : Dynamic ) continue;
			switch( t.follow() ) {
			case TInst(c,_): c.get(); // force build
			default:
			}
			var c = COMPONENTS.get(name);
			if( c == null ) {
				lastError = t;
				continue;
			}
			RESOLVED_COMPONENTS.set(name, { c : c, path : path });
			return c;
		}
		if( lastError != null )
			error(lastError.toString()+" does not define component "+name, pmin, pmax);
		return error("Could not load component '"+name+"'", pmin, pmax);
	}

	static function buildComponentsInit( m : MarkupParser.Markup, fields : Array<haxe.macro.Expr.Field>, pos : Position, isRoot = false ) : Expr {
		switch (m.kind) {
		case Node(name):
			var comp = loadComponent(name, m.pmin, m.pmin+name.length);
			var args = comp.getConstructorArgs();
			var eargs = [];
			if( isRoot ) {
				if( m.arguments.length > 0 )
					error("Arguments should be passed in super constructor", m.pmin, m.pmax);
			} else {
				if( m.arguments.length > args.length )
					error("Component requires "+args.length+" arguments ("+[for( a in args ) a.name].join(", ")+")", m.pmin, m.pmin + name.length);
				for( i in 0...args.length ) {
					var a = args[i];
					var cur = m.arguments[i];
					if( cur == null ) {
						if( !a.opt )
							error("Missing argument "+a.name+"("+a.type.toString()+")", m.pmin, m.pmin + name.length);
						continue;
					}
					switch( cur.value ) {
					case Code(expr):
						eargs.push({ expr : ECheckType(expr,a.type), pos : expr.pos });
					case RawValue(v):
						error("TODO", cur.pmin, cur.pmax);
					}
				}
			}
			var avalues = [];
			var aexprs = [];
			for( attr in m.attributes ) {
				var p = Property.get(attr.name, false);
				if( p == null ) {
					error("Unknown property "+attr.name, attr.pmin, attr.pmin + attr.name.length);
					continue;
				}
				var h = comp.getHandler(p);
				if( h == null ) {
					error("Component "+comp.name+" does not handle property "+p.name, attr.pmin, attr.pmin + attr.name.length);
					continue;
				}
				switch( attr.value ) {
				case RawValue(aval):
					var css = try new CssParser().parseValue(aval) catch( e : Error ) error("Invalid CSS ("+e.message+")", attr.vmin + e.pmin, attr.vmin + e.pmax);
					try {
						if( h.parser == null ) throw new Property.InvalidProperty("Null parser");
						h.parser(css);
					} catch( e : Property.InvalidProperty ) {
						error("Invalid "+comp.name+"."+p.name+" value '"+aval+"'"+(e.message == null ? "" : " ("+e.message+")"), attr.vmin, attr.pmax);
					}
					avalues.push({ attr : attr.name, value : aval });
				case Code(e):
					var mc = Std.instance(comp, MetaComponent);
					var eset = null;
					while( mc != null ) {
						eset = mc.setExprs.get(p.name);
						if( eset != null || mc.parent == null ) break;
						mc = cast(mc.parent, MetaComponent);
					}
					aexprs.push(macro var attrib = $e);
					aexprs.push({ expr : EMeta({ pos : e.pos, name : ":privateAccess" }, { expr : ECall(eset,[macro cast tmp.obj,macro attrib]), pos : e.pos }), pos : e.pos });
					aexprs.push(macro @:privateAccess tmp.initStyle($v{p.name},attrib));
				}
			}
			var attributes = { expr : EObjectDecl([for( m in avalues ) { field : m.attr, expr : { expr : EConst(CString(m.value)), pos : pos } }]), pos : pos };
			var ct = comp.baseType;
			var exprs : Array<Expr> = if( isRoot ) {
				var baseCheck = { expr : ECheckType(macro this,ct), pos : Context.currentPos() };
				[
					(macro var tmp : domkit.Element<$componentsType> = domkit.Element.create($v{name},$attributes,(null:domkit.Element<$componentsType>),$baseCheck)),
					(macro document = new domkit.Document(tmp)),
				];
			} else
				[macro var tmp = domkit.Element.create($v{name},$attributes, tmp, null, [$a{eargs}])];
			var declaredIds = new Map<String,Bool>();
			for( a in m.attributes )
				if( a.name == "id" ) {
					var field = switch( a.value ) {
					case RawValue(v): v;
					default: continue;
					}
					var isArray = StringTools.endsWith(field,"[]");
					if( isArray ) {
						field = field.substr(0,field.length-2);
						exprs.push(macro this.$field.push(cast tmp.obj));
						if( !declaredIds.exists(field) ) {
							declaredIds.set(field, true);
							fields.push({
								name : field,
								access : [APublic],
								pos : makePos(pos, a.pmin, a.pmax),
								kind : FVar(TPath({ pack : [], name : "Array", params : [TPType(ct)] }), macro []),
							});
						}
					} else {
						exprs.push(macro this.$field = cast tmp.obj);
						fields.push({
							name : field,
							access : [APublic],
							pos : makePos(pos, a.pmin, a.pmax),
							kind : FVar(ct),
						});
					}
				}
			for( e in aexprs )
				exprs.push(e);
			for( c in m.children ) {
				var e = buildComponentsInit(c, fields, pos);
				if( e != null ) exprs.push(e);
			}
			return macro $b{exprs};
		case Text(text):
			var c = loadComponent("text",m.pmin, m.pmax);
			return macro {
				var tmp = domkit.Element.create("text",null,tmp);
				tmp.setAttribute("text",VString($v{text}));
			};
		case CodeBlock(expr):
			var expr = Context.parseInlineString(expr,makePos(pos, m.pmin, m.pmax));
			switch( expr.expr ) {
			case EConst(CIdent(v)):
				return macro domkit.Element.create("object",null,tmp,$i{v});
			default:
				replaceLoop(expr, function(m) return buildComponentsInit(m, fields, pos));
			}
			return expr;
		case CustomText(id):
			var args = m.arguments == null ? null : [for( a in m.arguments ) switch( a.value ) {
				case RawValue(v): { expr : EConst(CString(v)), pos : makePos(pos, a.pmin, a.pmax) };
				case Code(e): e;
			}];
			var expr = customTextParser(id, args, makePos(pos, m.pmin, m.pmax));
			if( expr == null ) error("Unsupported custom text", m.pmin, m.pmax);
			var c = loadComponent("text",m.pmin, m.pmax);
			return macro {
				var tmp = domkit.Element.create("text",null,tmp);
				tmp.setAttribute("text",VString($expr));
			};
		}
	}

	static function replaceLoop( e : Expr, callb : MarkupParser.Markup -> Expr ) {
		switch( e.expr ) {
		case EMeta({ name : ":markup" },{ expr : EConst(CString(str)), pos : pos }):
			var p = new MarkupParser();
			var pinf = Context.getPosInfos(pos);
			var root = p.parse(str,pinf.file,pinf.min).children[0];
			e.expr = callb(root).expr;
		default:
			haxe.macro.ExprTools.iter(e,function(e) replaceLoop(e,callb));
		}
	}

	static function lookupInterface( c : haxe.macro.Type.Ref<haxe.macro.Type.ClassType>, name : String ) {
		while( true ) {
			var cg = c.get();
			for( i in cg.interfaces ) {
				if( i.t.toString() == name )
					return true;
				if( lookupInterface(i.t, name) )
					return true;
			}
			var sup = cg.superClass;
			if( sup == null )
				break;
			c = sup.t;
		}
		return false;
	}

	public static function buildObject() {
		var cl = Context.getLocalClass().get();
		var fields = Context.getBuildFields();
		var hasDocument = false;
		for( f in fields )
			if( f.name == "SRC" ) {
				switch( f.kind ) {
				case FVar(_,{ expr : EMeta({ name : ":markup" },{ expr : EConst(CString(str)) }), pos : pos }):
					try {
						var p = new MarkupParser();
						var pinf = Context.getPosInfos(pos);
						var root = p.parse(str,pinf.file,pinf.min).children[0];

						var initExpr = buildComponentsInit(root, fields, pos, true);
						var csup = cl.superClass;
						var isFirst = true;
						while( csup != null ) {
							var cl = csup.t.get();
							if( cl.meta.has(":hasDomKitSrc") ) {
								isFirst = false;
								break;
							}
							csup = cl.superClass;
						}
						hasDocument = true;

						if( isFirst )
							fields = fields.concat((macro class {
								public var document : domkit.Document<$componentsType>;
								public function setStyle( style : domkit.CssStyle ) {
									document.setStyle(style);
								}
							}).fields);

						var found = false;
						for( f in fields )
							if( f.name == "new" ) {
								switch( f.kind ) {
								case FFun(f):
									function replace( e : Expr ) {
										switch( e.expr ) {
										case ECall({ expr : EConst(CIdent("initComponent")) },[]): e.expr = initExpr.expr; found = true;
										default: haxe.macro.ExprTools.iter(e, replace);
										}
									}
									replace(f.expr);
									if( !found ) Context.error("Constructor missing initComponent() call", f.expr.pos);
									break;
								default:
								}
							}
						if( !found )
							Context.error("Missing constructor", Context.currentPos());

					} catch( e : Error ) {
						Context.error(e.message, makePos(pos,e.pmin,e.pmax));
					}
					cl.meta.add(":hasDomkitSrc", [], cl.pos);
					fields.remove(f);
					break;
				default:
				}
			}
		var isComp = cl.meta.has(":uiComp");
		if( isComp ) {
			try {
				var m = new MetaComponent(Context.getLocalType(), fields);
				m.hasDocument = hasDocument;
				if( componentsType == null ) componentsType = m.baseType;
				Context.defineType(m.buildRuntimeComponent(componentsType,fields));
				var t = m.getRuntimeComponentType();
				fields.push((macro class {
					static var ref : $t = null;
				}).fields[0]);
				COMPONENTS.set(m.name, m);
			} catch( e : MetaComponent.MetaError ) {
				Context.error(e.message, e.position);
			}
		}
		return fields;
	}


	static function error( msg : String, pmin : Int, pmax : Int = -1 ) : Dynamic {
		throw new Error(msg, pmin, pmax);
	}

	static function makePos( p : Position, pmin : Int, pmax : Int ) {
		var p0 = Context.getPosInfos(p);
		return Context.makePosition({ min : pmin, max : pmax, file : p0.file });
	}

	#end

}