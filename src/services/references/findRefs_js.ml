(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

let ( >>= ) = Lwt_result.Infix.( >>= )

let ( >>| ) = Base.Result.( >>| )

open Utils_js

(** Sort and dedup by loc.

    This will have to be revisited if we ever need to report multiple ref kinds for
    a single location. *)
let sort_and_dedup refs =
  Base.List.dedup_and_sort ~compare:(fun (_, loc1) (_, loc2) -> Loc.compare loc1 loc2) refs

let local_variable_refs scope_info loc =
  match VariableFindRefs.local_find_refs scope_info loc with
  | None -> (None, loc)
  | Some (var_refs, local_def_loc) -> (Some var_refs, local_def_loc)

let global_property_refs ~reader ~genv ~env ~def_info ~multi_hop =
  match def_info with
  | None -> Lwt.return (Ok None)
  | Some def_info ->
    let%lwt refs = PropertyFindRefs.find_global_refs ~reader genv env ~multi_hop def_info in
    Lwt.return (refs >>| Base.Option.some)

let local_property_refs ~reader ~options ~file_key ~ast_info ~scope_info ~def_info =
  match def_info with
  | None -> Lwt.return (Ok None)
  | Some def_info ->
    let refs =
      PropertyFindRefs.find_local_refs ~reader ~options file_key ast_info scope_info def_info
    in
    Lwt.return (refs >>| Base.Option.some)

let find_global_refs ~reader ~genv ~env ~profiling ~file_input ~line ~col ~multi_hop =
  let options = genv.ServerEnv.options in
  let filename = File_input.filename_of_file_input file_input in
  let file_key = File_key.SourceFile filename in
  let loc = Loc.cursor (Some file_key) line col in
  File_input.content_of_file_input file_input %>>= fun content ->
  FindRefsUtils.compute_ast_result options file_key content %>>= fun ast_info ->
  (* Start by running local variable find references *)
  let (ast, _, _) = ast_info in
  let scope_info = Scope_builder.program ~with_types:true ast in
  let (var_refs, loc) = local_variable_refs scope_info loc in
  (* Run get-def on the local loc *)
  GetDefUtils.get_def_info ~reader ~options !env profiling file_key ast_info loc >>= fun def_info ->
  (* Then run property find-refs *)
  global_property_refs ~reader ~genv ~env ~def_info ~multi_hop >>= fun prop_refs ->
  (* If property find-refs returned nothing (for example if we are importing from an untyped
     * module), then fall back on the local refs we computed earlier. *)
  let (prop_refs, dep_count) =
    match prop_refs with
    | Some (prop_refs, dep_count) -> (Some prop_refs, dep_count)
    | None -> (None, None)
  in
  let refs = Base.Option.first_some prop_refs var_refs in
  let refs = Base.Option.map ~f:(fun (name, refs) -> (name, sort_and_dedup refs)) refs in
  Lwt.return (Ok (refs, dep_count))

let find_local_refs ~reader ~options ~env ~profiling ~file_input ~line ~col =
  let filename = File_input.filename_of_file_input file_input in
  let file_key = File_key.SourceFile filename in
  let loc = Loc.cursor (Some file_key) line col in
  File_input.content_of_file_input file_input %>>= fun content ->
  FindRefsUtils.compute_ast_result options file_key content %>>= fun ast_info ->
  (* Start by running local variable find references *)
  let (ast, _, _) = ast_info in
  let scope_info = Scope_builder.program ~with_types:true ast in
  let (var_refs, loc) = local_variable_refs scope_info loc in
  (* Run get-def on the local loc *)
  GetDefUtils.get_def_info ~reader ~options env profiling file_key ast_info loc >>= fun def_info ->
  (* Then run property find-refs *)
  local_property_refs ~reader ~options ~file_key ~ast_info ~scope_info ~def_info
  >>= fun prop_refs ->
  (* If property find-refs returned nothing (for example if we are importing from an untyped
     * module), then fall back on the local refs we computed earlier. *)
  let refs = Base.Option.first_some prop_refs var_refs in
  let refs = Base.Option.map ~f:(fun (name, refs) -> (name, sort_and_dedup refs)) refs in
  Lwt.return (Ok refs)
