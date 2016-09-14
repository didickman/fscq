Require Import ProofIrrelevance.
Require Import PeanoNat String List FMapAVL Structures.OrderedTypeEx.
Require Import Relation_Operators Operators_Properties.
Require Import Morphisms.
Require Import VerdiTactics.
Require Import StringMap MoreMapFacts.
Require Import Mem AsyncDisk PredCrash Prog ProgMonad SepAuto.
Require Import Gensym.
Require Import Word.
Require Import Go.

Import ListNotations.

(* TODO: Split into more files *)

Set Implicit Arguments.

(* Don't print (elt:=...) everywhere *)
Unset Printing Implicit Defensive.

Hint Constructors step fail_step crash_step exec.

(* TODO What here is actually necessary? *)

Class GoWrapper (WrappedType: Type) :=
  { wrap:      WrappedType -> Go.value;
    wrap_inj:  forall v v', wrap v = wrap v' -> v = v' }.

Inductive ScopeItem :=
| SItem A {H: GoWrapper A} (v : A).

Notation "∅" := (VarMap.empty _) : map_scope.
Notation "k ->> v ;  m" := (VarMap.add k v m) (at level 21, right associativity) : map_scope.
Notation "k ~> v ;  m" := (VarMap.add k (SItem v) m) (at level 21, right associativity) : map_scope.
Delimit Scope map_scope with map.

Definition Scope := VarMap.t ScopeItem.

Definition SameValues (s : VarMap.t Go.value) (tenv : Scope) :=
  Forall
    (fun item =>
      match item with
      | (key, SItem val) =>
        match VarMap.find key s with
        | Some v => v = wrap val
        | None => False
        end
      end)
    (VarMap.elements tenv).

Notation "ENV \u2272 TENV" := (SameValues ENV TENV) (at level 50).

Definition ProgOk T env eprog (sprog : prog T) (initial_tstate : Scope) (final_tstate : T -> Scope) :=
  forall initial_state hm,
    (snd initial_state) \u2272 initial_tstate ->
    forall out,
      Go.exec env (initial_state, eprog) out ->
    (forall final_state, out = Go.Finished final_state ->
      exists r hm',
        exec (fst initial_state) hm sprog (Finished (fst final_state) hm' r) /\
        (snd final_state) \u2272 (final_tstate r)) /\
    (forall final_disk,
      out = Go.Crashed final_disk ->
      exists hm',
        exec (fst initial_state) hm sprog (Crashed T final_disk hm')) /\
    (out = Go.Failed ->
      exec (fst initial_state) hm sprog (Failed T)).

Notation "'EXTRACT' SP {{ A }} EP {{ B }} // EV" :=
  (ProgOk EV EP%go SP A B)
    (at level 60, format "'[v' 'EXTRACT'  SP '/' '{{'  A  '}}' '/'    EP '/' '{{'  B  '}}'  //  EV ']'").

Ltac GoWrapper_t :=
  abstract (repeat match goal with
                   | _ => progress intros
                   | [ H : _ * _ |- _ ] => destruct H
                   | [ H : unit |- _ ] => destruct H
                   | [ H : _ = _ |- _ ] => inversion H; solve [eauto using inj_pair2]
                   | _ => solve [eauto using inj_pair2]
                   end).

Instance GoWrapper_Num : GoWrapper W.
Proof.
  refine {| wrap := Go.Val Go.Num;
            wrap_inj := _ |}; GoWrapper_t.
Defined.

Instance GoWrapper_Bool : GoWrapper bool.
Proof.
  refine {| wrap := Go.Val Go.Bool;
            wrap_inj := _ |}; GoWrapper_t.
Defined.

Instance GoWrapper_valu : GoWrapper valu.
Proof.
  refine {| wrap := Go.Val Go.DiskBlock;
            wrap_inj := _ |}; GoWrapper_t.
Defined.

Instance GoWrapper_unit : GoWrapper unit.
Proof.
  refine {| wrap := Go.Val Go.EmptyStruct;
            wrap_inj := _ |}; GoWrapper_t.
Defined.

Instance GoWrapper_dec {P Q} : GoWrapper ({P} + {Q}).
Proof.
  refine {| wrap := fun (v : {P} + {Q}) => if v then Go.Val Go.Bool true else Go.Val Go.Bool false;
            wrap_inj := _ |}.
  destruct v; destruct v'; intro; try eapply Go.value_inj in H; try congruence; intros; f_equal; try apply proof_irrelevance.
Qed.

Definition extract_code := projT1.

Local Open Scope string_scope.

Local Open Scope map_scope.

Ltac find_cases var st := case_eq (VarMap.find var st); [
  let v := fresh "v" in
  let He := fresh "He" in
  intros v He; rewrite ?He in *
| let Hne := fresh "Hne" in
  intro Hne; rewrite Hne in *; exfalso; solve [ discriminate || intuition idtac ] ].


Ltac inv_exec :=
  match goal with
  | [ H : Go.step _ _ _ |- _ ] => invc H
  | [ H : Go.exec _ _ _ |- _ ] => invc H
  | [ H : Go.crash_step _ |- _ ] => invc H
  end; try discriminate.

Example micro_noop : sigT (fun p =>
  EXTRACT Ret tt
  {{ ∅ }}
    p
  {{ fun _ => ∅ }} // StringMap.empty _).
Proof.
  eexists.
  intro.
  instantiate (1 := Go.Skip).
  intros.
  repeat inv_exec;
    repeat split; intros; subst; try discriminate.
  contradiction H2.
  econstructor; eauto.
  find_inversion. eauto.
Defined.

(*
Theorem extract_finish_equiv : forall A {H: GoWrapper A} scope cscope pr p,
  (forall d0,
    {{ SItemDisk (NTSome "disk") d0 (ret tt) :: scope }}
      p
    {{ [ SItemDisk (NTSome "disk") d0 pr; SItemRet (NTSome "out") d0 pr ] }} {{ cscope }} // disk_env) ->
  forall st st' d0,
    st \u2272 ( SItemDisk (NTSome "disk") d0 (ret tt) :: scope) ->
    RunsTo disk_env p st st' ->
    exists d', find "disk" st' = Some (Disk d') /\ exists r, @computes_to A pr d0 d' r.
Proof.
  unfold ProgOk.
  intros.
  specialize (H0 d0 st ltac:(auto)).
  intuition.
  specialize (H5 st' ltac:(auto)).
  simpl in *.
  find_cases "disk" st.
  find_cases "disk" st'.
  intuition.
  repeat deex.
  intuition eauto.
Qed.

Theorem extract_crash_equiv : forall A pscope scope pr p,
  (forall d0,
    {{ SItemDisk (NTSome "disk") d0 (ret tt) :: scope }}
      p
    {{ pscope }} {{ [ SItemDiskCrash (NTSome "disk") d0 pr ] }} // disk_env) ->
  forall st p' st' d0,
    st \u2272 (SItemDisk (NTSome "disk") d0 (ret tt) :: scope) ->
    (Go.step disk_env)^* (p, st) (p', st') ->
    exists d', find "disk" st' = Some (Disk d') /\ @computes_to_crash A pr d0 d'.
Proof.
  unfold ProgOk.
  intros.
  specialize (H d0 st ltac:(auto)).
  intuition.
  specialize (H st' p').
  simpl in *.
  intuition. find_cases "disk" st'.
  repeat deex. eauto.
Qed.
*)


Lemma extract_equiv_prog : forall T env A (B : T -> _) pr1 pr2 p,
  prog_equiv pr1 pr2 ->
  EXTRACT pr1
  {{ A }}
    p
  {{ B }} // env ->
  EXTRACT pr2
  {{ A }}
    p
  {{ B }} // env.
Proof.
  unfold prog_equiv, ProgOk.
  intros.
  setoid_rewrite <- H.
  auto.
Qed.

Lemma possible_sync_refl : forall AT AEQ (m: @mem AT AEQ _), possible_sync m m.
Proof.
  intros.
  unfold possible_sync.
  intros.
  destruct (m a).
  destruct p.
  right. repeat eexists. unfold incl. eauto.
  eauto.
Qed.

Hint Immediate possible_sync_refl.

Ltac set_hyp_evars :=
  repeat match goal with
  | [ H : context[?e] |- _ ] =>
    is_evar e;
    let H := fresh in
    set (H := e) in *
  end.

Module VarMapFacts := FMapFacts.WFacts_fun(Nat_as_OT)(VarMap).
Module Import MoreVarMapFacts := MoreFacts_fun(Nat_as_OT)(VarMap).

Ltac map_rewrites := rewrite
                       ?StringMapFacts.remove_neq_o, ?StringMapFacts.remove_eq_o,
                     ?StringMapFacts.add_neq_o, ?StringMapFacts.add_eq_o,
                     ?StringMapFacts.empty_o,
                       ?VarMapFacts.remove_neq_o, ?VarMapFacts.remove_eq_o,
                     ?VarMapFacts.add_neq_o, ?VarMapFacts.add_eq_o,
                     ?VarMapFacts.empty_o
    in * by congruence.

Ltac maps := unfold SameValues in *; repeat match goal with
  | [ H : Forall _ (VarMap.elements _) |- _ ] =>
      let H1 := fresh H in
      let H2 := fresh H in
      apply Forall_elements_add in H;
      destruct H as [H1 H2];
      try (eapply Forall_elements_equal in H2; [ | apply add_remove_comm; solve [ congruence ] ])
  | [ |- Forall _ (VarMap.elements _) ] =>
      apply Forall_elements_add; split
  | _ => discriminate
  | _ => congruence
  | _ => set_evars; set_hyp_evars; progress map_rewrites; subst_evars
  end.

Ltac find_all_cases :=
  repeat match goal with
  | [ H : match VarMap.find ?d ?v with | Some _ => _ | None => _ end |- _ ] => find_cases d v
  end; subst.


Lemma read_fails_not_present:
  forall env vvar avar (a : W) d s,
    VarMap.find avar s = Some (wrap a) ->
    ~ (exists st' p', Go.step env (d, s, Go.DiskRead vvar (Go.Var avar)) (st', p')) ->
    d a = None.
Proof.
  intros.
  assert (~exists v0, d a = Some v0).
  intuition.
  deex.
  contradiction H0.
  destruct v0. repeat eexists. econstructor; eauto.
  destruct (d a); eauto. contradiction H1. eauto.
Qed.
Hint Resolve read_fails_not_present.


Lemma write_fails_not_present:
  forall env vvar avar (a : W) (v : valu) d s,
    VarMap.find vvar s = Some (wrap v) ->
    VarMap.find avar s = Some (wrap a) ->
    ~ (exists st' p', Go.step env (d, s, Go.DiskWrite (Go.Var avar) (Go.Var vvar)) (st', p')) ->
    d a = None.
Proof.
  intros.
  assert (~exists v0, d a = Some v0).
  intuition.
  deex.
  contradiction H1.
  destruct v0. repeat eexists. econstructor; eauto.
  destruct (d a); eauto. contradiction H2. eauto.
Qed.
Hint Resolve write_fails_not_present.

Lemma skip_is_final :
  forall d s, Go.is_final (d, s, Go.Skip).
Proof.
  unfold Go.is_final; trivial.
Qed.

Hint Resolve skip_is_final.

Ltac match_finds :=
  match goal with
    | [ H1: VarMap.find ?a ?s = ?v1, H2: VarMap.find ?a ?s = ?v2 |- _ ] => rewrite H1 in H2; try invc H2
  end.

Ltac invert_trivial H :=
  match type of H with
    | ?con ?a = ?con ?b =>
      let H' := fresh in
      assert (a = b) as H' by exact (match H with eq_refl => eq_refl end); clear H; rename H' into H
  end.

Ltac find_inversion_safe :=
  match goal with
    | [ H : ?X ?a = ?X ?b |- _ ] =>
      (unify a b; fail 1) ||
      let He := fresh in
      assert (a = b) as He by solve [inversion H; auto with equalities | invert_trivial H; auto with equalities]; clear H; subst
  end.

Ltac destruct_pair :=
  match goal with
    | [ H : _ * _ |- _ ] => destruct H
  end.

Ltac inv_exec_progok :=
  repeat destruct_pair; repeat inv_exec; simpl in *;
  intuition (subst; try discriminate;
             repeat find_inversion_safe; repeat match_finds; repeat find_inversion_safe;  simpl in *;
               try solve [ exfalso; intuition eauto 10 ]; eauto 10).

Example micro_write : sigT (fun p => forall a v,
  EXTRACT Write a v
  {{ 0 ~> a; 1 ~> v; ∅ }}
    p
  {{ fun _ => ∅ }} // StringMap.empty _).
Proof.
  eexists.
  intros.
  instantiate (1 := (Go.DiskWrite (Go.Var 0) (Go.Var 1))%go).
  intro. intros.
  maps.
  find_all_cases.
  inv_exec_progok.
Defined.

Lemma CompileSkip : forall env A,
  EXTRACT Ret tt
  {{ A }}
    Go.Skip
  {{ fun _ => A }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
Qed.

Hint Extern 1 (Go.eval _ _ = _) =>
unfold Go.eval.

Hint Extern 1 (Go.step _ (_, Go.Assign _ _) _) =>
eapply Go.StepAssign.
Hint Constructors Go.step.

Lemma CompileConst : forall env A var (v v0 : nat),
  EXTRACT Ret v
  {{ var ~> v0; A }}
    var <~ Go.Const v
  {{ fun ret => var ~> ret; A }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
  do 2 eexists.
  intuition eauto.
  maps; eauto.
  eapply forall_In_Forall_elements. intros.
  pose proof (Forall_elements_forall_In H1).
  simpl in *.
  destruct (VarMapFacts.eq_dec k var); maps; try discriminate.
  specialize (H2 k v1). maps. intuition.

  contradiction H1.
  repeat eexists.
  unfold SameValues in *.
  rewrite Forall_elements_add in *.
  intuition.
  find_all_cases.
  eauto.
Qed.

Ltac forwardauto1 H :=
  repeat eforward H; conclude H eauto.

Ltac forwardauto H :=
  forwardauto1 H; repeat forwardauto1 H.

Ltac forward_solve_step :=
  match goal with
    | _ => progress intuition eauto
    | [ H : forall _, _ |- _ ] => forwardauto H
    | _ => deex
  end.

Ltac forward_solve :=
  repeat forward_solve_step.

Definition vars_subset V (subset set : VarMap.t V) := forall k, VarMap.find k set = None -> VarMap.find k subset = None.

Lemma can_always_declare:
  forall env t xp st,
    (forall var, Go.source_stmt (xp var)) ->
    exists st'' p'',
      Go.step env (st, Go.Declare t xp) (st'', p'').
Proof.
  intros.
  destruct st.
  repeat eexists.
  econstructor; eauto.
  admit. (* Have to pick a variable not already there *)
  Unshelve.
  exact 0.
Admitted.

(* TODO: simplify wrapper system *)
Lemma CompileDeclare :
  forall env T t (zeroval : Go.type_denote t) {H : GoWrapper(Go.type_denote t)} A B (p : prog T) xp,
    wrap zeroval = Go.default_value t ->
    (forall var, Go.source_stmt (xp var)) ->
    (forall ret, vars_subset (B ret) A) ->
    (forall var,
       VarMap.find var A = None ->
       EXTRACT p
       {{ var ~> zeroval; A }}
         xp var
       {{ fun ret => B ret }} // env) ->
    EXTRACT p
    {{ A }}
      Go.Declare t xp
    {{ fun ret => B ret }} // env.
Proof.
  unfold ProgOk.
  intros.
  repeat destruct_pair.
  destruct out.
  - intuition try discriminate.
    find_eapply_lem_hyp Go.ExecFailed_Steps.
    repeat deex.
    invc H7.
    contradiction H9.
    eapply can_always_declare; auto.

    destruct_pair.
    hnf in s.
    destruct_pair.
    simpl in *.
    invc H8.
    specialize (H3 var).
    forward H3.
    {
      maps.
      pose proof (Forall_elements_forall_In H4) as HA.
      case_eq (VarMap.find var A); intros.
      forward_solve.
      destruct s.
      rewrite H15 in HA.
      intuition.
      trivial.
    }
    intuition.
    specialize (H8 (r0, var ->> Go.default_value t; t0) hm).
    forward H8.
    {
      clear H8.
      simpl in *; maps.
      eapply forall_In_Forall_elements; intros.
      pose proof (Forall_elements_forall_In H4).
      destruct (VarMapFacts.eq_dec k var); maps.
      specialize (H8 k v).
      intuition.
    }
    intuition.
    simpl in *.
    eapply Go.Steps_Seq in H10.
    intuition.
    forward_solve.
    eapply H11; eauto.
    eapply Go.Steps_ExecFailed in H10; eauto.
    intuition.
    contradiction H9.
    hnf in H8.
    simpl in H8.
    subst.
    eauto.
    intuition.
    contradiction H9.
    repeat deex.
    eauto.

    forward_solve.
    invc H12.
    contradiction H9.
    destruct st'. 
    repeat eexists. econstructor; eauto.
    invc H8.
    invc H13.
    contradiction H5.
    auto.
    invc H8.

  - find_eapply_lem_hyp Go.ExecFinished_Steps.
    find_eapply_lem_hyp Go.Steps_runsto; auto.
    invc H5.
    find_eapply_lem_hyp Go.runsto_Steps.
    find_eapply_lem_hyp Go.Steps_ExecFinished.
    specialize (H3 var).
    forward H3.
    {
      maps.
      simpl in *.
      pose proof (Forall_elements_forall_In H4).
      case_eq (VarMap.find var A); intros.
      destruct s.
      forward_solve.
      rewrite H10 in H5.
      intuition.
      auto.
    }
    intuition try discriminate.
    destruct_pair.
    specialize (H6 (r, var ->> Go.default_value t; t0) hm).
    forward H6.
    {
      clear H6.
      simpl in *; maps.
      eapply forall_In_Forall_elements; intros.
      pose proof (Forall_elements_forall_In H4).
      destruct (VarMapFacts.eq_dec k var); maps.
      specialize (H7 k v).
      intuition.
    }
    invc H3.
    forward_solve.
    simpl in *.
    repeat eexists; eauto.
    maps.
    eapply forall_In_Forall_elements; intros.
    pose proof (Forall_elements_forall_In H11).
    forward_solve.
    destruct v.
    destruct (VarMapFacts.eq_dec k var).
    subst.
    maps.
    unfold vars_subset in H1.
    specialize (H2 r1 var).
    intuition.
    congruence.
    maps.
    constructor; eauto.
    
  - invc H5; [ | invc H7 ].
    invc H6.
    find_eapply_lem_hyp Go.ExecCrashed_Steps.
    repeat deex; try discriminate.
    find_inversion_safe.
    find_eapply_lem_hyp Go.Steps_Seq.
    intuition.
    repeat deex.
    invc H8.
    eapply Go.Steps_ExecCrashed in H6; eauto.
    simpl in *.
    specialize (H3 var).
    forward H3.
    {
      maps.
      simpl in *.
      pose proof (Forall_elements_forall_In H4).
      case_eq (VarMap.find var A); intros.
      destruct s.
      forward_solve.
      rewrite H11 in H5.
      intuition.
      auto.
    }
    intuition.
    specialize (H8 (r, var ->> Go.default_value t; t0) hm).
    forward H8.
    {
      clear H8.
      simpl in *; maps.
      eapply forall_In_Forall_elements; intros.
      pose proof (Forall_elements_forall_In H4).
      destruct (VarMapFacts.eq_dec k var); maps.
      specialize (H8 k v).
      intuition.
    }
    forward_solve.

    deex.
    invc H7.
    invc H8.
    invc H5.
    invc H9.
    invc H8.
    invc H5.
Qed.


Lemma CompileVar : forall env A var T (v : T) {H : GoWrapper T},
  EXTRACT Ret v
  {{ var ~> v; A }}
    Go.Skip
  {{ fun ret => var ~> ret; A }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
Qed.

Import Go.

Lemma CompileBind : forall T T' {H: GoWrapper T} env A (B : T' -> _) p f xp xf var,
  EXTRACT p
  {{ A }}
    xp
  {{ fun ret => var ~> ret; A }} // env ->
  (forall (a : T),
    EXTRACT f a
    {{ var ~> a; A }}
      xf
    {{ B }} // env) ->
  EXTRACT Bind p f
  {{ A }}
    xp; xf
  {{ B }} // env.
Proof.
  unfold ProgOk.
  intuition subst.

  - find_eapply_lem_hyp ExecFinished_Steps. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex; try discriminate.
    find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFinished.
    forward_solve.

  - find_eapply_lem_hyp ExecCrashed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + invc H5. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forward_solve.
    + destruct st'. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forward_solve.

  - find_eapply_lem_hyp ExecFailed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + eapply Steps_ExecFailed in H5; eauto.
      forward_solve.
      unfold is_final; simpl; intuition subst.
      contradiction H6. eauto.
      intuition. repeat deex.
      contradiction H6. eauto.
    + destruct st'. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFailed; eauto.
      forward_solve.
Qed.

Lemma hoare_weaken_post : forall T env A (B1 B2 : T -> _) pr p,
  (forall x k e, VarMap.find k (B2 x) = Some e -> VarMap.find k (B1 x) = Some e) ->
  EXTRACT pr
  {{ A }} p {{ B1 }} // env ->
  EXTRACT pr
  {{ A }} p {{ B2 }} // env.
Proof.
  unfold ProgOk.
  intros.
  forwardauto H0.
  intuition subst;
  forwardauto H3; repeat deex;
  repeat eexists; eauto;
  unfold SameValues in *;
  apply forall_In_Forall_elements; intros;
  eapply Forall_elements_forall_In in H6; eauto.
Qed.

Lemma hoare_strengthen_pre : forall T env A1 A2 (B : T -> _) pr p,
  (forall k e, VarMap.find k A1 = Some e -> VarMap.find k A2 = Some e) ->
  EXTRACT pr
  {{ A1 }} p {{ B }} // env ->
  EXTRACT pr
  {{ A2 }} p {{ B }} // env.
Proof.
  unfold ProgOk.
  intros.
  repeat eforward H0.
  forward H0.
  unfold SameValues in *.
  apply forall_In_Forall_elements; intros;
  eapply Forall_elements_forall_In in H1; eauto.
  forwardauto H0.
  intuition.
Qed.

Lemma hoare_equal_post : forall T env A (B1 B2 : T -> _) pr p,
  (forall x, VarMap.Equal (B1 x) (B2 x)) ->
  EXTRACT pr
  {{ A }} p {{ B1 }} // env ->
  EXTRACT pr
  {{ A }} p {{ B2 }} // env.
Proof.
  intros.
  eapply hoare_weaken_post.
  intros.
  rewrite H; eauto.
  assumption.
Qed.

Lemma hoare_simpl_add_same_post : forall T V {H: GoWrapper V} env A (B : T -> _) k (fv : T -> V) v0 pr p,
  EXTRACT pr
  {{ A }} p {{ fun r => k ~> fv r; B r }} // env ->
  EXTRACT pr
  {{ A }} p {{ fun r => k ~> fv r; k ~> v0; B r }} // env.
Proof.
  intros.
  eapply hoare_equal_post.
  intros.
  hnf.
  intros.
  instantiate (B1 := fun x => k ~> fv x; B x).
  simpl.
  rewrite MoreVarMapFacts.add_same.
  trivial.
  assumption.
Qed.

Lemma CompileBindDiscard : forall T' env A (B : T' -> _) p f xp xf,
  EXTRACT p
  {{ A }}
    xp
  {{ fun _ => A }} // env ->
  EXTRACT f
  {{ A }}
    xf
  {{ B }} // env ->
  EXTRACT Bind p (fun (_ : T') => f)
  {{ A }}
    xp; xf
  {{ B }} // env.
Proof.
  unfold ProgOk.
  intuition subst.

  - find_eapply_lem_hyp ExecFinished_Steps. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex; try discriminate.
    find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFinished.
    (* [forward_solve] is not really good enough *)
    forwardauto H. intuition.
    forwardauto H2. repeat deex.
    forward_solve.

  - find_eapply_lem_hyp ExecCrashed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + invc H4. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forward_solve.
    + destruct st'. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forwardauto H. intuition.
      forwardauto H2. repeat deex.
      forward_solve.

  - find_eapply_lem_hyp ExecFailed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + eapply Steps_ExecFailed in H4; eauto.
      forward_solve.
      unfold is_final; simpl; intuition subst.
      contradiction H5. eauto.
      intuition. repeat deex.
      contradiction H5. eauto.
    + destruct st'. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFailed; eauto.
      forwardauto H. intuition.
      forwardauto H3. repeat deex.
      forward_solve.

  Unshelve.
  all: auto.
Qed.

Example micro_inc : sigT (fun p => forall x,
  EXTRACT Ret (1 + x)
  {{ 0 ~> x; ∅ }}
    p
  {{ fun ret => 0 ~> ret; ∅ }} // StringMap.empty _).
Proof.
  eexists.
  intros.
  instantiate (1 := (0 <~ Const 1 + Var 0)%go).
  intro. intros.
  inv_exec_progok.
  maps.
  find_all_cases.
  simpl in *.
  repeat eexists; eauto. maps; eauto.
  simpl; congruence.
  eapply forall_In_Forall_elements.
  intros.
  rewrite remove_empty in *.
  maps.

  contradiction H1. repeat eexists. econstructor; simpl.
  maps. simpl in *. find_all_cases. eauto.
  eauto.
  maps. simpl in *. find_all_cases. eauto.
  eauto.
  trivial.
Qed.

Lemma CompileIf : forall P Q {H1 : GoWrapper ({P}+{Q})}
                         T {H : GoWrapper T}
                         A B env (pt pf : prog T) (cond : {P} + {Q}) xpt xpf xcond retvar condvar,
  retvar <> condvar ->
  EXTRACT pt
  {{ A }}
    xpt
  {{ B }} // env ->
  EXTRACT pf
  {{ A }}
    xpf
  {{ B }} // env ->
  EXTRACT Ret cond
  {{ A }}
    xcond
  {{ fun ret => condvar ~> ret; A }} // env ->
  EXTRACT if cond then pt else pf
  {{ A }}
   xcond ; If Var condvar Then xpt Else xpf EndIf
  {{ B }} // env.
Proof.
  unfold ProgOk.
  intuition.
  econstructor. intuition.
Admitted.

Lemma CompileWeq : forall A (a b : valu) env xa xb retvar avar bvar,
  avar <> bvar ->
  avar <> retvar ->
  bvar <> retvar ->
  EXTRACT Ret a
  {{ A }}
    xa
  {{ fun ret => avar ~> ret; A }} // env ->
  (forall (av : valu),
  EXTRACT Ret b
  {{ avar ~> av; A }}
    xb
  {{ fun ret => bvar ~> ret; avar ~> av; A }} // env) ->
  EXTRACT Ret (weq a b)
  {{ A }}
    xa ; xb ; retvar <~ (Var avar = Var bvar)
  {{ fun ret => retvar ~> ret; A }} // env.
Proof.
  unfold ProgOk.
  intuition.
Admitted.

Lemma CompileRead : forall env F avar vvar a,
  EXTRACT Read a
  {{ avar ~> a; F }}
    DiskRead vvar (Var avar)
  {{ fun ret => vvar ~> ret; avar ~> a; F }} // env.
Proof.
  unfold ProgOk.
  intros.
  maps.
  find_all_cases.
  inv_exec_progok.
  do 2 eexists.
  intuition eauto.
  maps; simpl in *; eauto.

  (* TODO: automate the hell out of this! *)
  destruct (Nat.eq_dec vvar avar).
  {
    subst.
    eapply Forall_elements_equal; [ | eapply add_remove_same ].
    eapply forall_In_Forall_elements. intros.
    eapply Forall_elements_forall_In in H2; eauto. destruct v0.
    destruct (Nat.eq_dec k avar).
    + subst. maps.
    + maps.

  }
  {
    eapply Forall_elements_equal; [ | eapply add_remove_comm'; congruence ]. maps.
    + rewrite He. trivial.
    + eapply Forall_elements_equal; [ | eapply remove_remove_comm; congruence ].
      eapply forall_In_Forall_elements. intros.
      destruct (Nat.eq_dec k avar). {
        subst. maps.
      }
      destruct (Nat.eq_dec k vvar). {
        subst. maps.
      }
      maps.
      eapply Forall_elements_forall_In in H2; eauto.
      maps.
  }
Qed.

Lemma CompileWrite : forall env F avar vvar a v,
  avar <> vvar ->
  EXTRACT Write a v
  {{ avar ~> a; vvar ~> v; F }}
    DiskWrite (Var avar) (Var vvar)
  {{ fun _ => avar ~> a; vvar ~> v; F }} // env.
Proof.
  unfold ProgOk.
  intros.
  maps.
  find_all_cases.

  inv_exec_progok.

  repeat eexists; eauto.

  maps. rewrite He0. eauto.
  eapply forall_In_Forall_elements. intros.
  pose proof (Forall_elements_forall_In H4).
  simpl in *.
  destruct (Nat.eq_dec k vvar); maps. {
    find_inversion. subst. rewrite He. auto.
  }
  destruct (Nat.eq_dec k avar); maps.
  specialize (H1 k v). conclude H1 ltac:(maps; eauto).
  simpl in *. eauto.
Qed.


Definition voidfunc2 A B C {WA: GoWrapper A} {WB: GoWrapper B} name (src : A -> B -> prog C) env :=
  forall avar bvar,
    avar <> bvar ->
    forall a b, EXTRACT src a b
           {{ avar ~> a; bvar ~> b; ∅ }}
             Call [] name [avar; bvar]
           {{ fun _ => ∅ (* TODO: could remember a & b if they are of aliasable type *) }} // env.


Lemma extract_voidfunc2_call :
  forall A B C {WA: GoWrapper A} {WB: GoWrapper B} name (src : A -> B -> prog C) arga argb env,
    forall and body ss,
      (forall a b, EXTRACT src a b {{ arga ~> a; argb ~> b; ∅ }} body {{ fun _ => ∅ }} // env) ->
      StringMap.find name env = Some {|
                                    ParamVars := [arga; argb];
                                    RetParamVars := [];
                                    Body := body;
                                    (* ret_not_in_args := rnia; *)
                                    args_no_dup := and;
                                    body_source := ss;
                                  |} ->
      voidfunc2 name src env.
Proof.      
  unfold voidfunc2.
  intros A B C WA WB name src arga argb env and body ss Hex Henv avar bvar Hvarne a b.
  specialize (Hex a b).
  intro.
  intros.
  intuition subst.
  - find_eapply_lem_hyp ExecFinished_Steps.
    find_eapply_lem_hyp Steps_runsto.
    invc H0.
    find_eapply_lem_hyp runsto_Steps.
    find_eapply_lem_hyp Steps_ExecFinished.
    rewrite Henv in H4.
    find_inversion_safe.
    subst_definitions. unfold sel in *. simpl in *. unfold ProgOk in *.
    repeat eforward Hex.
    forward Hex.
    shelve.
    forward_solve.
    simpl in *.
    do 2 eexists.
    intuition eauto.
    maps; find_all_cases; repeat find_inversion_safe; simpl.
    eauto.

    econstructor.
    econstructor.
  - find_eapply_lem_hyp ExecCrashed_Steps.
    repeat deex.
    invc H1; [ solve [ invc H2 ] | ].
    invc H0.
    rewrite Henv in H7.
    find_inversion_safe. unfold sel in *. simpl in *.
    assert (exists bp', (Go.step env)^* (d, callee_s, body) (final_disk, s', bp') /\ p' = InCall s [arga; argb] [] [avar; bvar] [] bp').
    {
      remember callee_s.
      clear callee_s Heqt.
      generalize H3 H2. clear. intros.
      prep_induction H3; induction H3; intros; subst.
      - find_inversion.
        eauto using rt1n_refl.
      - invc H0.
        + destruct st'.
          forwardauto IHclos_refl_trans_1n; deex.
          eauto using rt1n_front.
        + invc H3. invc H2. invc H.
    }
    deex.
    eapply Steps_ExecCrashed in H1.
    unfold ProgOk in *.
    repeat eforward Hex.
    forward Hex.
    shelve.
    forward_solve.
    invc H2. trivial.
  - find_eapply_lem_hyp ExecFailed_Steps.
    repeat deex.
    invc H1.
    + contradiction H3.
      destruct st'. repeat eexists. econstructor; eauto.
      unfold sel; simpl in *.
      maps.
      find_all_cases.
      trivial.
    + invc H2.
      rewrite Henv in H8.
      find_inversion_safe. simpl in *.
      assert (exists bp', (Go.step env)^* (d, callee_s, body) (st', bp') /\ p' = InCall s [arga; argb] [] [avar; bvar] [] bp').
      {
        remember callee_s.
        clear callee_s Heqt.
        generalize H4 H0 H3. clear. intros.
        prep_induction H4; induction H4; intros; subst.
        - find_inversion.
          eauto using rt1n_refl.
        - invc H0.
          + destruct st'0.
            forwardauto IHclos_refl_trans_1n; deex.
            eauto using rt1n_front.
          + invc H4. contradiction H1. auto. invc H.
      }
      deex.
      eapply Steps_ExecFailed in H2.
      unfold ProgOk in *.
      repeat eforward Hex.
      forward Hex. shelve.
      forward_solve.
      intuition.
      contradiction H3.
      unfold is_final in *; simpl in *; subst.
      destruct st'. repeat eexists. eapply StepEndCall; simpl; eauto.
      intuition.
      contradiction H3.
      repeat deex; eauto.

  Unshelve.
  * simpl in *.
    maps.
    find_all_cases.
    find_inversion_safe.
    maps.
    find_all_cases.
    find_inversion_safe.
    eapply Forall_elements_remove_weaken.
    eapply forall_In_Forall_elements.
    intros.
    destruct (Nat.eq_dec k argb).
    subst. maps. find_inversion_safe.
    find_copy_eapply_lem_hyp NoDup_bool_sound.
    invc H.
    assert (arga <> argb).
    intro. subst. contradiction H2. constructor. auto.
    maps.
    intros. apply sumbool_to_bool_dec.
    maps.
  * (* argh *)
    simpl in *.
    subst_definitions.
    maps.
    find_all_cases.
    find_inversion_safe.
    maps.
    eapply Forall_elements_remove_weaken.
    eapply forall_In_Forall_elements.
    intros.
    destruct (Nat.eq_dec k argb).
    subst. maps. find_inversion_safe.
    find_copy_eapply_lem_hyp NoDup_bool_sound.
    invc H.
    assert (arga <> argb).
    intro. subst. contradiction H8. constructor. auto.
    find_cases avar s.
    find_cases bvar s.
    find_inversion_safe.
    maps.
    intros. apply sumbool_to_bool_dec.
    maps.
  * unfold sel in *; simpl in *.
    subst_definitions.
    simpl in *.
    find_cases avar s.
    find_cases bvar s.
    find_inversion_safe.
    maps.
    rewrite He in *.
    auto.
    eapply Forall_elements_remove_weaken.
    eapply forall_In_Forall_elements.
    intros.
    destruct (Nat.eq_dec k argb).
    subst. maps. find_inversion_safe.
    find_copy_eapply_lem_hyp NoDup_bool_sound.
    invc H.
    assert (arga <> argb).
    intro. subst. contradiction H9. constructor. auto.
    maps.
    rewrite He0 in *. auto.
    intros. apply sumbool_to_bool_dec.
    maps.
Qed.

Ltac reduce_or_fallback term continuation fallback :=
  match nat with
  | _ => let term' := (eval red in term) in let res := continuation term' in constr:(res)
  | _ => constr:(fallback)
  end.
Ltac find_fast value fmap :=
  match fmap with
  | @VarMap.empty _       => constr:(@None string)
  | VarMap.add ?k (SItem ?v) _    => let eq := constr:(eq_refl v : v = value) in
                     constr:(Some k)
  | VarMap.add ?k _ ?tail => let ret := find_fast value tail in constr:(ret)
  | ?other         => let ret := reduce_or_fallback fmap ltac:(fun reduced => find_fast value reduced) (@None string) in
                     constr:(ret)
  end.

Ltac match_variable_names_right :=
  match goal with
  | [ H : VarMap.find _ ?m = _ |- _ ] =>
    repeat match goal with
    | [ |- context[VarMap.add ?k (SItem ?v) _]] =>
      is_evar k;
      match find_fast v m with
      | Some ?k' => unify k k'
      end
    end
  end.

Ltac match_variable_names_left :=
  try (match goal with
  | [ H : context[VarMap.add ?k (SItem ?v) _] |- _ ] =>
    is_evar k;
    match goal with
    | [ |- VarMap.find _ ?m = _ ] =>
      match find_fast v m with
      | Some ?k' => unify k k'
      end
    end
  end; match_variable_names_left).

Ltac keys_equal_cases :=
  match goal with
  | [ H : VarMap.find ?k0 ?m = _ |- _ ] =>
    match goal with
      | [ H : context[VarMap.add ?k (SItem ?v) _] |- _ ] =>
        match goal with
          | [ H : k0 = k |- _ ] => fail 1
          | [ H : k0 <> k |- _ ] => fail 1
          | [ H : ~ k0 = k |- _ ] => fail 1
          | _ => destruct (VarMapFacts.eq_dec k0 k); maps
        end
    end
  end.

Ltac prepare_for_frame :=
  match goal with
  | [ H : _ <> ?k |- _ ] =>
    rewrite add_add_comm with (k1 := k) by congruence; maps (* A bit inefficient: don't need to rerun maps if it's still the same [k] *)
  end.

Ltac match_scopes :=
  simpl; intros;
  match_variable_names_left; match_variable_names_right;
  try eassumption; (* TODO this is not going to cover everything *)
  repeat keys_equal_cases;
  repeat prepare_for_frame;
  try eassumption.

Hint Constructors source_stmt.

Ltac compile_step :=
  match goal with
  | [ |- @sigT _ _ ] => eexists; intros
  | _ => eapply CompileBindDiscard
  | [ |- EXTRACT Bind ?p ?q {{ _ }} _ {{ _ }} // _ ] =>
    let v := fresh "var" in
    match type of p with (* TODO: shouldn't be necessary to type switch here *)
      | prog nat =>
        eapply CompileDeclare with (zeroval := 0) (t := Num); auto; [ shelve | shelve | intro v; intro ]
      | prog valu =>
        eapply CompileDeclare with (zeroval := $0) (t := DiskBlock); auto; [ shelve | shelve | intro v; intro ]
    end;
    eapply CompileBind with (var := v); intros
  | _ => eapply CompileConst
  | [ |- EXTRACT Ret tt {{ _ }} _ {{ _ }} // _ ] =>
    eapply hoare_weaken_post; [ | eapply CompileSkip ]; try match_scopes; maps
  | [ |- EXTRACT Read ?a {{ ?pre }} _ {{ _ }} // _ ] =>
    match find_fast a pre with
    | Some ?k =>
      eapply hoare_strengthen_pre; [ | eapply hoare_weaken_post; [ |
        eapply CompileRead with (avar := k) ]]; try match_scopes; maps
    end
  | [ |- EXTRACT Write ?a ?v {{ ?pre }} _ {{ _ }} // _ ] =>
    match find_fast a pre with
    | Some ?ka =>
      match find_fast v pre with
      | Some ?kv =>
        eapply hoare_strengthen_pre; [ | eapply hoare_weaken_post; [ |
          eapply CompileWrite with (avar := ka) (vvar := kv) ]]; try match_scopes; maps
      end
    end
  | [ H : voidfunc2 ?name ?f ?env |- EXTRACT ?f ?a ?b {{ ?pre }} _ {{ _ }} // ?env ] =>
    match find_fast a pre with
      | Some ?ka =>
        match find_fast b pre with
            | Some ?kb =>
              eapply hoare_weaken_post; [ | eapply hoare_strengthen_pre; [ |
                eapply H ] ]; try match_scopes; maps
        end
    end
  | [ |- EXTRACT ?f ?a {{ ?pre }} _ {{ _ }} // _ ] =>
    match f with
      | Ret => fail 2
      | _ => idtac
    end;
    match find_fast a pre with
      | None =>
        eapply extract_equiv_prog; [ eapply bind_left_id | ]
    end
  | [ |- EXTRACT ?f ?a ?b {{ ?pre }} _ {{ _ }} // _ ] =>
    match find_fast a pre with
    | None =>
      eapply extract_equiv_prog; [
        let arg := fresh "arg" in
        set (arg := f a b);
        pattern a in arg; subst arg;
        eapply bind_left_id | ]
    end
  end.

Ltac compile := repeat compile_step.

Example compile_one_write : sigT (fun p =>
  EXTRACT Write 1 $0
  {{ ∅ }}
    p
  {{ fun _ => ∅ }} // StringMap.empty _).
Proof.
  compile_step.
  compile_step.
  lazymatch goal with
  | [ |- EXTRACT Bind ?p ?q {{ _ }} _ {{ _ }} // _ ] =>
    let v := fresh "var" in
    match type of p with (* TODO: shouldn't be necessary to type switch here *)
      | prog nat =>
        eapply CompileDeclare with (zeroval := 0) (t := Num); auto; [ shelve | shelve | intro v; intros ]
      | prog valu =>
        eapply CompileDeclare with (zeroval := $0) (t := DiskBlock); auto; [ shelve | shelve | intro v; intros ]
    end
    (* eapply CompileBind with (var := v); intros *)
  end.
  eapply CompileBind with (var := var0).
  eapply hoare_simpl_add_same_post.
  eapply CompileConst.
  compile_step.
  shelve.
  shelve.
  eapply CompileBind; intros.
  compile.
  
  eapply CompileDeclare with (zeroval := $0) (t := DiskBlock); auto; intros.
  shelve.
  maps.
  eapply CompileDeclare with (zeroval := 0) (t := Num); auto; intros.
  shelve.
  intro. maps.
  eapply extract_equiv_prog; [
      let arg := fresh "arg" in
      set (arg := Write 1 $0);
        pattern 1 in arg; subst arg;
        eapply bind_left_id | ].
  eapply CompileBind with (var := var1).
  eapply hoare_weaken_post.
  shelve.
  eapply CompileConst.
  intros.
  eapply hoare_weaken_post.
  shelve.
  eapply hoare_strengthen_pre.
  shelve.
  eapply CompileWrite with (avar := var1) (vvar := var0).
  intro. maps.
  Unshelve.
  all: try constructor; auto; try match_scopes.
  instantiate (F := VarMap.empty _). (* TODO: automate somehow *)
  maps.
Defined.





Definition swap_prog a b :=
  va <- Read a;
  vb <- Read b;
  Write a vb;;
  Write b va;;
  Ret tt.

Example extract_swap_1_2 : forall env, sigT (fun p =>
  EXTRACT swap_prog 1 2 {{ ∅ }} p {{ fun _ => ∅ }} // env).
Proof.
  intros.
  eexists.
  eapply CompileDeclareNum; intros.
  eapply CompileDeclareNum; intros.
Defined.
Eval lazy in projT1 (extract_swap_prog ∅).

Lemma extract_swap_prog : forall env, sigT (fun p =>
  forall a b, EXTRACT swap_prog a b {{ "a" ~> a; "b" ~> b; ∅ }} p {{ fun _ => ∅ }} // env).
Proof.
  intros.
  compile.
Defined.
Eval lazy in projT1 (extract_swap_prog ∅).

Opaque swap_prog.

Definition extract_swap_prog_corr env := projT2 (extract_swap_prog env).
Hint Resolve extract_swap_prog_corr : extractions.

Definition swap_env : Env :=
  ("swap" ->> {|
           ArgVars := ["a"; "b"];
           RetVar := None; Body := projT1 (extract_swap_prog ∅);
           ret_not_in_args := ltac:(auto); args_no_dup := ltac:(auto); body_source := ltac:(auto);
         |}; ∅).


Lemma swap_func : voidfunc2 "swap" swap_prog swap_env.
Proof.
  unfold voidfunc2.
  intros.
  eapply extract_voidfunc2_call; eauto with extractions.
  unfold swap_env; map_rewrites. auto.
Qed.
Hint Resolve swap_func : funcs.

Definition call_swap :=
  swap_prog 0 1;;
  Ret tt.

Example extract_call_swap :
  forall env,
    voidfunc2 "swap" swap_prog env ->
    sigT (fun p =>
          EXTRACT call_swap {{ ∅ }} p {{ fun _ => ∅ }} // env).
Proof.
  intros.
  compile.
Defined.

Example extract_call_swap_top :
    sigT (fun p =>
          EXTRACT call_swap {{ ∅ }} p {{ fun _ => ∅ }} // swap_env).
Proof.
  apply extract_call_swap.
  auto with funcs.
Defined.
Eval lazy in projT1 (extract_call_swap_top).

Definition rot3_prog :=
  swap_prog 0 1;;
  swap_prog 1 2;;
  Ret tt.

Example extract_rot3_prog :
  forall env,
    voidfunc2 "swap" swap_prog env ->
    sigT (fun p =>
          EXTRACT rot3_prog {{ ∅ }} p {{ fun _ => ∅ }} // env).
Proof.
  intros.
  compile.
Defined.

Example extract_rot3_prog_top :
    sigT (fun p =>
          EXTRACT rot3_prog {{ ∅ }} p {{ fun _ => ∅ }} // swap_env).
Proof.
  apply extract_rot3_prog.
  auto with funcs.
Defined.
Eval lazy in projT1 (extract_rot3_prog_top).

Definition swap2_prog :=
  a <- Read 0;
  b <- Read 1;
  if weq a b then
    Ret tt
  else
    Write 0 b;;
    Write 1 a;;
    Ret tt.

Example micro_swap2 : sigT (fun p =>
  EXTRACT swap2_prog {{ ∅ }} p {{ fun _ => ∅ }} // ∅).
Proof.
  compile.

  eapply hoare_weaken_post; [ | eapply CompileIf with (condvar := "c0") (retvar := "r") ];
    try match_scopes; maps.

  apply GoWrapper_unit.
  compile. apply H.

  compile.
  eapply CompileWeq.

  shelve.
  shelve.
  shelve.

  eapply hoare_strengthen_pre.
  2: eapply CompileVar.
  match_scopes.

  intros.
  eapply hoare_strengthen_pre.
  2: eapply CompileVar.
  match_scopes.

  Unshelve.
  all: congruence.
Defined.
Eval lazy in projT1 micro_swap2.