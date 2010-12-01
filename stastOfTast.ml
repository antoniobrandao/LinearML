open Utils
open Tast

type t = type_expr IMap.t

let check_terminates (p, tyl) = 
  List.iter (function
    | _, Stast.Tany -> Error.infinite_loop p 
    | _ -> ()) tyl

let check_apply (p, ty) = 
  match ty with
  | Stast.Tprim _ -> Error.poly_is_not_prim p
  | _ -> ()

module ObsCheck = struct
  open Stast

  let rec type_expr p (_, ty) = type_expr_ p ty
  and type_expr_ p = function
  | Tany 
  | Tprim _
  | Tvar _ -> ()
  | Tid (_, x) when x = Naming.tobs -> Error.obs_not_value p
  | Tid _ -> ()
  | Tapply ((_, x), _) when x = Naming.tobs -> 
      Error.obs_not_allowed p

  | Tapply (_, tyl) -> type_expr_list p tyl
  | Tfun (_, tyl) -> type_expr_list p tyl

  and type_expr_list p (_, tyl) = 
    List.iter (type_expr p) tyl


  let tuple ((p, _) as tyl,_) = type_expr_list p tyl
  let expr ((p, _) as ty, _) = type_expr p ty
  let type_expr_list ((p, _) as tyl) = type_expr_list p tyl 
  
end

module Env = struct

  let rec module_ md = 
    List.fold_left def IMap.empty md.md_defs

  and def t ((p, x), (tyl1, _), (tyl2, _)) = 
    IMap.add x (p, Neast.Tfun (tyl1, tyl2)) t
end

let rec program mdl = 
  List.map module_ mdl 

and module_ md = 
  let t = Env.module_ md in {
    Stast.md_id = md.md_id ;
    Stast.md_decls = List.map (decl t) md.md_decls ;
    Stast.md_defs = List.map (def t) md.md_defs ;
  }

and decl t = function
  | Neast.Dalgebric td -> Stast.Dalgebric (tdef t td)
  | Neast.Drecord td -> Stast.Drecord (tdef t td)
  | Neast.Dval (x, ty, v) -> Stast.Dval (x, type_expr t ty, v) 

and tdef t td = {
  Stast.td_id = td.Neast.td_id ;
  Stast.td_args = td.Neast.td_args ;
  Stast.td_map = IMap.map (id_type t) td.Neast.td_map ;
}

and id_type t (x, tyl) = 
  let tyl = type_expr_list t tyl in
  ObsCheck.type_expr_list tyl ;
  x, tyl

and type_expr t (p, ty) = p, type_expr_ t ty
and type_expr_ t = function
    | Neast.Tany -> Stast.Tany
    | Neast.Tprim ty -> Stast.Tprim ty
    | Neast.Tvar x -> Stast.Tvar x
    | Neast.Tid x -> Stast.Tid x
    | Neast.Tapply (x, tyl) -> 
	let tyl = type_expr_list t tyl in
	List.iter check_apply (snd tyl) ;
	Stast.Tapply (x, tyl)
    | Neast.Tfun (tyl1, tyl2) -> 
	Stast.Tfun (type_expr_list t tyl1, type_expr_list t tyl2)

and local_def t x =
  let l = IMap.fold (fun x _ acc -> x :: acc) x [] in
  match l with
  | [] -> assert false 
  | x :: _ -> 
      (* TODO bug fix on   let rec f x = f f *)
      (* TODO bug fix on (fun x -> x x) (fun x -> x x) must check for loops *)
      (* This could probably be memoized ... not sure it is worth it *)
      type_expr_ t (snd (IMap.find x t))

and type_expr_list t (p, tyl) = p, List.map (type_expr t) tyl

and def t (x, p, e) = 
  let e = tuple t e in
  ObsCheck.tuple e ;
  x, pat t p, e

and pat t (tyl, ptl) = type_expr_list t tyl, List.map (pat_tuple t) ptl
and pat_tuple t (tyl, pel) = type_expr_list t tyl, List.map (pat_el t) pel
and pat_el t (ty, p) = type_expr t ty, pat_ t p
and pat_ t = function
  | Pany -> Stast.Pany
  | Pid x -> Stast.Pid x
  | Pvalue v -> Stast.Pvalue v
  | Pvariant (x, p) -> Stast.Pvariant (x, pat t p)
  | Precord pfl -> Stast.Precord (List.map (pat_field t) pfl)
  | Pas (x, p) -> Stast.Pas (x, pat t p)

and pat_field t (p, pa) = p, pat_field_ t pa
and pat_field_ t = function
  | PFany -> Stast.PFany
  | PFid x -> Stast.PFid x
  | PField (x, p) -> Stast.PField (x, pat t p)

and tuple t (tyl, tpl) = type_expr_list t tyl, List.map (tuple_pos t) tpl
and tuple_pos t (tyl, e) = 
  let tyl = type_expr_list t tyl in
  tyl, expr_ t tyl e
and expr t (ty, e) = 
  let ty = type_expr t ty in
  ty, expr_ t (fst ty, [ty]) e

and expr_ t ty = function
  | Eid x -> Stast.Eid x
  | Evalue v -> Stast.Evalue v
  | Evariant (id, e) -> 
      let e = tuple t e in
      ObsCheck.tuple e ;
      Stast.Evariant (id, e)
  | Ebinop (bop, e1, e2) -> 
      Stast.Ebinop (bop, expr t e1, expr t e2)
  | Euop (uop, e) -> Stast.Euop (uop, expr t e)
  | Erecord (itl) -> Stast.Erecord (List.map (id_tuple t) itl)
  | Ewith (e, itl) -> 
      let e = expr t e in
      ObsCheck.expr e ;
      Stast.Ewith (e, List.map (id_tuple t) itl)
  | Efield (e, x) -> Stast.Efield (expr t e, x)
  | Ematch (e, pal) -> Stast.Ematch (tuple t e, List.map (action t) pal)
  | Elet (p, e1, e2) -> 
      let e1 = tuple t e1 in
      let e2 = tuple t e2 in
      ObsCheck.tuple e1 ;
      ObsCheck.tuple e2 ;
      Stast.Elet (pat t p, e1, e2)
  | Eif (e1, e2, e3) -> 
      let e2 = tuple t e2 in
      let e3 = tuple t e3 in
      ObsCheck.tuple e2 ;
      ObsCheck.tuple e3 ;
      Stast.Eif (expr t e1, e2, e3)
  | Eapply (x, e) -> 
      check_terminates ty ;
      Stast.Eapply (x, tuple t e)
  | Eseq (e1, e2) -> 
      let e2 = tuple t e2 in
      ObsCheck.tuple e2 ;
      Stast.Eseq (expr t e1, e2)
  | Eobs x -> Stast.Eobs x

and id_tuple t (x, e) = 
  let e = tuple t e in
  ObsCheck.tuple e ;
  x, e

and action t (p, a) = 
  let e = tuple t a in
  ObsCheck.tuple e ;
  pat t p, e
