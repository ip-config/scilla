(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.
  
  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.
 
  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 
  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

open Syntax
open Core
open ErrorUtils
open MonadUtil
open EvalMonad
open EvalMonad.Let_syntax
open Stdint
open ContractUtil
open PrettyPrinters
open TypeUtil
open BuiltIns
open Gas

open ParserUtil
module SR = ParserRep
module ER = ParserRep
module EvalSyntax = ScillaSyntax (SR) (ER)
module EvalTypeUtilities = TypeUtilities (SR) (ER)
module EvalBuiltIns = ScillaBuiltIns (SR) (ER) 
module EvalGas = ScillaGas (SR) (ER)

open EvalSyntax
    
(* Return a builtin_op wrapped in EvalMonad *)
let builtin_executor f arg_tps arg_lits =
  let%bind (_, ret_typ, op) =
    fromR @@ EvalBuiltIns.BuiltInDictionary.find_builtin_op f arg_tps in
  let%bind cost = fromR @@ EvalGas.builtin_cost f arg_lits in
  let res () = op arg_lits ret_typ in
  checkwrap_opR res (Uint64.of_int cost)

(* Add a check that the just evaluated statement was in our gas limit. *)
let stmt_gas_wrap scon sloc =
  let%bind cost = fromR @@ EvalGas.stmt_cost scon in
  let err = (mk_error1 "Ran out of gas evaluating statement" sloc) in 
  let dummy () = pure () in (* the operation is already executed unfortunately *)
    checkwrap_op dummy (Uint64.of_int cost) err

(*****************************************************)
(* Update-only execution environment for expressions *)
(*****************************************************)
module Env = struct
  type ident = string

  (* Environment *)
  type t = (string * literal) list
  [@@deriving sexp]

  (* Pretty-printing *)
  let rec pp_value = pp_literal
  and pp ?f:(f = fun (_ : (string * literal)) -> true) e =
    (* FIXME: Do not print folds *)
    let e_filtered = List.filter e ~f:f in
    let ps = List.map e_filtered
        ~f:(fun (k, v) -> " [" ^ k ^ " -> " ^ (pp_value v) ^ "]") in
    let cs = String.concat ~sep:",\n " ps in
    "{" ^ cs ^ " }"

  let empty = []

  let bind e k v =
    (k, v) :: List.filter ~f:(fun z -> fst z <> k) e

  let bind_all e kvs = 
    List.fold_left ~init:e ~f:(fun z (k, v) -> bind z k v) kvs

  (* Unbind those identifiers "id" from "e" which have "f id" false. *)
  let filter e ~f =
    List.filter e ~f:(fun (id, _) -> f id)

  let lookup e k =
    let i = get_id k in
    match List.find ~f:(fun z -> fst z = i) e with 
    | Some x -> pure @@ snd x
    | None -> fail1 (sprintf
        "Identifier \"%s\" is not bound in environment:\n" i) (get_rep k)
end


(**************************************************)
(*                 Blockchain State               *)
(**************************************************)
module BlockchainState = struct
  type t = (string * literal) list

  let lookup e k =
    match List.find ~f:(fun z -> fst z = k) e with 
    | Some x -> pure @@ snd x
    | None -> fail0 @@ sprintf
        "No value for key \"%s\" at in the blockchain state:\n%s"
        k (pp_literal_map e)  
end

(**************************************************)
(*          Runtime contract configuration        *)
(**************************************************)
module Configuration = struct

  (* Runtime contract configuration and operations with it *)
  type t = {
    (* Immutable variables *)
    env : Env.t;
    (* Contract fields *)
    fields : (string * literal) list;
    (* Contract balance *)
    balance : uint128;
    (* Was incoming money accepted? *)
    accepted : bool;
    (* Blockchain state *)
    blockchain_state : BlockchainState.t;
    (* Available incoming funds *)
    incoming_funds : uint128;
    (* Emitted messages *)
    emitted : literal list;
    (* Emitted events *)
    events : literal list
  }

  let pp conf =
    let pp_env = Env.pp conf.env in
    let pp_fields = pp_literal_map conf.fields in
    let pp_balance = Uint128.to_string conf.balance in
    let pp_accepted = Bool.to_string conf.accepted in
    let pp_bc_conf = pp_literal_map conf.blockchain_state in
    let pp_in_funds = Uint128.to_string conf.incoming_funds in
    let pp_emitted = pp_literal_list conf.emitted in
    let pp_events = pp_literal_list conf.events in
    sprintf "Confuration\nEnv =\n%s\nFields =\n%s\nBalance =%s\nAccepted=%s\n\\
    Blockchain conf =\n%s\nIncoming funds = %s\nEmitted Messages =\n%s\nEmitted events =\n%s\n"
      pp_env pp_fields pp_balance pp_accepted pp_bc_conf pp_in_funds pp_emitted pp_events

  (*  Manipulations with configuartion *)
  
  let store st i l =
    let k = get_id i in
    let s = st.fields in
    match List.find s ~f:(fun (z, _) -> z = k) with
    | Some (_, l') -> pure @@
        ({st with
          fields = (k, l) :: List.filter ~f:(fun z -> fst z <> k) s}
        , G_Store(l', l))
    | None -> fail1 (sprintf "No field \"%s\" in contract.\n" k)
          (ER.get_loc (get_rep i))

  let load st k =
    let i = get_id k in
    if i = balance_label
    then
      (* Balance is a special case *)
      let l = UintLit (Uint128L st.balance) in
      pure (l, G_Load(l))
    else
      (* Evenrything else is from fields *)
      let s = st.fields in
      match List.find ~f:(fun z -> fst z = i) s with 
      | Some x -> pure @@ (snd x, G_Load(snd x))
      | None -> fail1 (sprintf "No field \"%s\" in contract.\n" i)
            (ER.get_loc (get_rep k))

  let map_update st m klist vopt =
    let s = st.fields in
    match List.find s ~f:(fun (z, _) -> z = (get_id m)) with
    | Some (_, Map((_,vt), mlit)) ->
      let rec recurser mlit' klist' vt' =
        (match klist' with
         (* we're at the last key, update literal. *)
         | [k] -> 
            (match vopt with
            | Some v ->
              Caml.Hashtbl.replace mlit' k v;
              pure @@ (st, G_MapUpdate ((List.length klist), (Some v)))
            | None ->
              Caml.Hashtbl.remove mlit' k;
              pure @@ (st, G_MapUpdate ((List.length klist), None)))
         | k :: krest ->
            (* we have more nested maps *)
            (match Caml.Hashtbl.find_opt mlit' k with
             | Some (Map((_, vt''), mlit'')) -> recurser mlit'' krest vt''
             | None ->
                if (is_some vopt) then (* not a delete operation. *)
                  (* We have more keys remaining, but no entry for "k".
                    So create an empty map for "k" and then proceed. *)
                  let mlit'' = Caml.Hashtbl.create 4 in
                  let%bind (kt'', vt'') = 
                    (match vt' with
                    | MapType (keytype, valtype) -> pure (keytype, valtype)
                    | _ -> fail1 (sprintf "Cannot index into map %s due to non-map type" (get_id m))
                            (ER.get_loc (get_rep m))
                    )
                    in
                      Caml.Hashtbl.replace mlit' k (Map((kt'', vt''), mlit''));
                      recurser mlit'' krest vt''
                else
                  (* No point removing a key that doesn't exist. *)
                  pure @@ (st, G_MapUpdate ((List.length klist), None))
              (* The remaining keys cannot be used for indexing as
                 we ran out of nested maps. *)
             | _ -> fail1 (sprintf "Cannot index into map %s. Too many index keys." (get_id m))
                      (ER.get_loc (get_rep m))
            )
          (* this cannot occur. *)
          | [] -> fail1 (sprintf "Internal error in updating map %s." (get_id m))
                    (ER.get_loc (get_rep m))
        )
      in
        recurser mlit klist vt
    | _ -> fail1 (sprintf "No map field \"%s\" in contract.\n" (get_id m))
            (ER.get_loc (get_rep m))

  let map_get st m klist fetchval =
    let s = st.fields in
    match List.find s ~f:(fun (z, _) -> z = (get_id m)) with
    | Some (_, Map((kt, vt), mlit)) ->

      (* The return type of this `MapGet` is Option (ret_val_type) *)
      let%bind ret_val_type =
        let rec recurser t nkeys =
          (match t, nkeys with
          | MapType (_, _), 0 -> pure vt
          | MapType (_, vt'), 1 -> pure vt'
          | MapType (_, vt'), nkeys' when nkeys' > 1 -> recurser vt' (nkeys-1)
          | _, _ -> fail1 (sprintf "Cannot index into map %s: Too many index keys or non-map type" (get_id m))
                    (ER.get_loc (get_rep m))
          )
        in
          recurser (MapType(kt, vt)) (List.length klist)
      in
      (* Recursively, index with each key and provide the indexed value. *)
      let rec recurser mlit' klist' vt' =
        (match klist' with
         | [k] -> 
          let%bind res = (match Caml.Hashtbl.find_opt mlit' k with
            | Some l ->
              if fetchval
              then pure @@ ADTValue ("Some", [vt'], [l])
              else pure @@ ADTValue ("True", [], [])
            | None -> 
              (* Just an assert. *)
              if vt' <> ret_val_type 
              then fail1 (sprintf "Failuing indexing into map %s. Internal error." (get_id m))
                  (ER.get_loc (get_rep m))
              else 
                if fetchval
                then pure @@ ADTValue ("None", [vt'], [])
                else pure @@ ADTValue ("False", [], []))
          in
            pure @@ (res, G_MapGet(List.length klist, Some res))
         | k :: krest ->
            (* we have more nested maps *)
            (match Caml.Hashtbl.find_opt mlit' k with
             | Some (Map((_, vt''), mlit'')) -> recurser mlit'' krest vt''
             | None ->
                (* No element found. Return none. *)
                let ret = 
                  if fetchval
                  then ADTValue ("None", [ret_val_type], [])
                  else ADTValue ("False", [], [])
                in
                pure @@ (ret, G_MapGet(List.length klist, Some ret))
              (* The remaining keys cannot be used for indexing as
                 we ran out of nested maps. *)
             | _ -> fail1 (sprintf "Cannot index into map %s. Too many index keys." (get_id m))
                      (ER.get_loc (get_rep m))
            )
         (* this cannot occur. *)
          | [] -> fail1 (sprintf "Internal error in retriving from map %s." (get_id m))
                    (ER.get_loc (get_rep m))
        )
      in
        recurser mlit klist vt
    | _ -> fail1 (sprintf "No map field \"%s\" in contract.\n" (get_id m))
            (ER.get_loc (get_rep m))

  let bind st k v =
    let e = st.env in
    {st with env = (k, v) :: List.filter ~f:(fun z -> fst z <> k) e}

  let lookup st k = Env.lookup st.env k

  let bc_lookup st k = BlockchainState.lookup st.blockchain_state k

  let accept_incoming st =
    let incoming' = st.incoming_funds in
    (* Although unsigned integer is used, and this check isn't
     * necessary, we have it just in case, some how a malformed
     * Uint128 literal manages to reach here.  *)
    if (Uint128.compare incoming' Uint128.zero) >= 0
    then
      let balance = Uint128.add st.balance incoming' in
      let accepted = true in
      let incoming_funds = Uint128.zero in
      pure @@ {st with balance; accepted; incoming_funds}
    else
      fail0 @@ sprintf "Incoming balance is negaitve (somehow):%s."
        (Uint128.to_string incoming')

  (* Check that message is well-formed before adding to the sending pool *)
  let rec validate_messages ls =
    (* Note: We don't need a whole lot of checks as the checker does it. *)
    let validate_msg_payload pl =
      let has_tag = List.exists pl ~f:(fun (k, _) -> k = "tag") in      
      if has_tag then pure true
      else fail0 @@ sprintf "Message contents have no \"tag\" field:\n[%s]"
          (pp_literal_map pl)
    in
    match ls with
      | (Msg pl) :: tl ->
          let%bind _ = validate_msg_payload pl in
          validate_messages tl
      | [] -> pure true
      | m :: _ -> fail0 @@ sprintf "This is not a message:\n%s" (pp_literal m)

  let validate_outgoing_message m' =
    let open ContractUtil.MessagePayload in
    match m' with
    | Msg m ->
      (* All outgoing messages must have certain mandatory fields *)
      let tag_found = List.exists ~f:(fun (s, _) -> s = tag_label) m in
      let amount_found = List.exists ~f:(fun (s, _) -> s = amount_label) m in
      let recipient_found = List.exists ~f:(fun (s, _) -> s = recipient_label) m in
      let uniq_entries = List.for_all m
        ~f:(fun e -> (List.count m ~f:(fun e' -> fst e = fst e')) = 1) in
      if tag_found && amount_found && recipient_found && uniq_entries then pure m'
      else fail0 @@ sprintf 
        "Message %s is missing a mandatory field or has duplicate fields." (pp_literal (Msg m))
    | _ -> fail0 @@ sprintf "Literal %s is not a message, cannot be sent." (pp_literal m')

  let send_messages conf ms =
    let%bind ls' = fromR @@ Datatypes.scilla_list_to_ocaml ms in
    let%bind ls = mapM ~f:validate_outgoing_message ls' in
    let old_emitted = conf.emitted in
    let emitted = old_emitted @ ls in
    pure ({conf with emitted}, G_SendMsgs ls)

  let validate_event m' =
    let open ContractUtil.MessagePayload in
    match m' with
    | Msg m ->
      (* All events must have certain mandatory fields *)
      let eventname_found = List.exists ~f:(fun (s, _) -> s = eventname_label) m in
      let uniq_entries = List.for_all m
        ~f:(fun e -> (List.count m ~f:(fun e' -> fst e = fst e')) = 1) in
      if eventname_found && uniq_entries then pure m'
      else fail0 @@ sprintf 
        "Event %s is missing a mandatory field or has duplicate fields." (pp_literal (Msg m))
    | _ -> fail0 @@ sprintf "Literal %s is not a valid event argument." (pp_literal m')


  let create_event conf l =
    let%bind event = 
      (match l with
       | Msg _  ->
           pure @@ l
       | _ -> fail0 @@ sprintf "Incorrect event parameter(s): %s\n" (pp_literal l))
    in
    let%bind event' = validate_event event in
    let old_events = conf.events in
    let events = event'::old_events in
    pure ({conf with events}, G_CreateEvnt event')
end

(*****************************************************)
(*         Contract state after initialization       *)
(*****************************************************)

module ContractState = struct

  type init_args = (string * literal) list 

  (* Runtime contract configuration and operations with it *)
  type t = {
    (* Immutable parameters *)
    env : Env.t;
    (* Contract fields *)
    fields : (string * literal) list;
    (* Contract balance *)
    balance : uint128;
  }

  (* Pretty-printing *)
  let pp cstate =
    let pp_params = Env.pp cstate.env in
    let pp_fields = pp_literal_map cstate.fields in
    let pp_balance = Uint128.to_string cstate.balance in
    sprintf "Contract State:\nImmutable parameters and libraries =\n%s\nMutable fields = \n%s\nBalance = %s\n"
      pp_params pp_fields pp_balance

end
