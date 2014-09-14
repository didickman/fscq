Require Import Prog.
Require Import Pred.
Require Import Hoare.
Require Import Omega.
Require Import SepAuto.
Require Import Word.
Require Import Nomega.
Require Import Recdef.
Require Import NArith.

Set Implicit Arguments.


(** * Some helpful [prog] combinators and proofs *)

Ltac inv_option :=
  match goal with
  | [ H: Some _ = Some _ |- _ ] => inversion H; clear H; subst
  | [ H: ?a = Some ?b |- _ ] =>
    match goal with
    | [ H': a = Some ?c |- _ ] =>
      match b with
      | c => fail 1
      | _ => rewrite H in H'
      end
    end
  end.

Ltac inv_exec_recover :=
  match goal with
  | [ H: exec_recover _ _ _ _ _ |- _ ] => inversion H; clear H; subst
  end.

Ltac inv_exec :=
  match goal with
  | [ H: exec _ _ _ _ |- _ ] => inversion H; clear H; subst
  end.

Theorem read_ok:
  forall (a:addr) (rx:valu->prog) (rec:prog),
  {{ exists v F, a |-> v * F
   * [[{{ a |-> v * F }} (rx v) >> rec]]
   * [[{{ a |-> v * F }} rec >> rec]]
  }} Read a rx >> rec.
Proof.
  unfold corr, exis; intros; repeat deex.
  repeat ( apply sep_star_lift2and in H; destruct H ).
  unfold lift in *; simpl in *.
  inv_exec_recover; auto; inv_exec.
  - apply ptsto_valid in H. congruence.
  - eapply H2. eauto.
    apply ptsto_valid in H. repeat inv_option.
    eauto.
  - eapply H2. eauto.
    apply ptsto_valid in H. repeat inv_option.
    eauto.
  - eapply H1; eauto.
Qed.

Hint Extern 1 ({{_}} progseq (Read _) _ >> _) => apply read_ok : prog.

(* write_ok' : start with a in domain of m and (diskIs m), end with (diskIs (upd m a v)) *)

Theorem write_ok:
  forall (a:addr) (v:valu) (rx:unit->prog) (rec:prog),
  {{ exists v0 F, a |-> v0 * F
   * [[{{ a |-> v * F }} rx tt >> rec]]
   * [[{{ a |-> v * F \/ a |-> v0 * F }} rec >> rec]]
  }} Write a v rx >> rec.
Proof.
  unfold corr, exis; intros; repeat deex.
  repeat ( apply sep_star_lift2and in H; destruct H ).
  unfold lift in *; simpl in *.
  inv_exec_recover; auto; inv_exec.
  - apply ptsto_valid in H. congruence.
  - eapply H2. instantiate (1:=upd m a v).
    eapply ptsto_upd; eauto.
    eauto.
  - eapply H2. instantiate (1:=upd m a v).
    eapply ptsto_upd; eauto.
    eauto.
  - eapply H1; unfold or; eauto.
Qed.

Hint Extern 1 ({{_}} progseq (Write _ _) _ >> _) => apply write_ok : prog.

Definition If_ P Q (b : {P} + {Q}) (p1 p2 : prog) :=
  if b then p1 else p2.

Theorem if_ok:
  forall P Q (b : {P}+{Q}) p1 p2 rec,
  {{ exists pre, pre
   * [[{{ pre * [[P]] }} p1 >> rec]]
   * [[{{ pre * [[Q]] }} p2 >> rec]]
  }} If_ b p1 p2 >> rec.
Proof.
  unfold corr, exis; intros; repeat deex.
  repeat ( apply sep_star_lift2and in H; destruct H ).
  destruct b.
  - eapply H2; eauto.
    eapply pimpl_apply; [|apply H].
    apply sep_star_lift_r.
    split; pred.
  - eapply H1; eauto.
    eapply pimpl_apply; [|apply H].
    apply sep_star_lift_r.
    split; pred.
Qed.

Hint Extern 1 ({{_}} If_ _ _ _ >> _) => apply if_ok : prog.
Notation "'If' b { p1 } 'else' { p2 }" := (If_ b p1 p2) (at level 9, b at level 0).

Fixpoint For_ (L : Set) (G : Type) (f : nat -> L -> (L -> prog) -> prog)
              (i n : nat) (l : L)
              (nocrash : G -> nat -> L -> pred)
              (crashed : G -> pred)
              (rx: L -> prog) : prog :=
  match n with
    | O => rx l
    | S n' => l' <- (f i l); (For_ f (S i) n' l' nocrash crashed rx)
  end.

Lemma wminus_Alt2: forall sz x y, (y <= x)%word ->
  @wminusN sz x y = wordBinN minus x y.
Proof.
  admit.
Qed.

Definition For_round (L : Set)
                     (f : addr -> L -> (L -> prog) -> prog)
                     (i : addr)
                     (nextround : L -> prog)
                     (l : L) : prog :=
  l' <- (f i l); nextround l'.

Function For_loop (L : Set) (G : Type) (f : addr -> L -> (L -> prog) -> prog)
                  (i n : addr)
                  (nocrash : G -> addr -> L -> pred)
                  (crashed : G -> pred)
                  (rx: L -> prog)
                  {measure wordToNat n}
                  : L -> prog :=
  match wlt_dec (natToWord addrlen 0) n with
  | left _ =>
    For_round f i
    (For_loop f (i ^+ (natToWord addrlen 1))
                (n ^- (natToWord addrlen 1))
                nocrash crashed rx)
  | right _ => rx
  end.
Proof.
  intros.

  clear teq.
  unfold wlt in w.
  repeat rewrite wordToN_nat in w.
  apply Nlt_out in w.
  repeat rewrite Nat2N.id in w.
  simpl in w.

  rewrite wminus_Alt.
  rewrite wminus_Alt2.
  unfold wordBinN.
  rewrite (@wordToNat_natToWord_idempotent' addrlen 1).
  rewrite wordToNat_natToWord_idempotent'.
  apply PeanoNat.Nat.sub_lt; omega.

  assert (wordToNat n < pow2 addrlen) by apply wordToNat_bound; omega.

  replace (1) with (wordToNat (natToWord addrlen 1)) by auto.
  apply wordToNat_bound.

  unfold wlt, not; intros.
  apply Nlt_out in H.
  repeat rewrite wordToN_nat in H.
  repeat rewrite Nat2N.id in H.
  simpl in H.
  omega.
Qed.

Theorem for_ok:
  forall (L : Set) (G : Type)
         f rx rec (nocrash : G -> nat -> L -> pred) (crashed : G -> pred)
         n i (li : L),
  {{ exists F (g:G), F * nocrash g i li
   * [[forall m l, F * nocrash g m l ==> F * crashed g]]
   * [[forall m lm rxm,
      i <= m < n + i ->
      (forall lSm, {{ F * nocrash g (S m) lSm }} (rxm lSm) >> rec) ->
      {{ F * nocrash g m lm }} f m lm rxm >> rec]]
   * [[forall lfinal, {{ F * nocrash g (n+i) lfinal }} (rx lfinal) >> rec]]
  }} (For_ f i n li nocrash crashed rx) >> rec.
Proof.
  induction n.
  - intros.
    apply corr_exists; intros.
    apply corr_exists; intros.
    eapply pimpl_pre; repeat ( apply sep_star_lift_l; intros ).
    + unfold pimpl; intuition pred.
    + unfold pimpl; pred.
  - intros.
    apply corr_exists; intros.
    apply corr_exists; intros.
    eapply pimpl_pre; repeat ( apply sep_star_lift_l; intros ).
    + unfold pimpl; intuition idtac.
      eapply H0; try omega.
      intros.
      eapply pimpl_ok.
      apply IHn.
      apply pimpl_exists_r; exists a.
      apply pimpl_exists_r; exists a0.
      repeat ( apply sep_star_lift_r; apply pimpl_and_split );
        unfold pimpl, lift; intuition eauto.
      apply H0; eauto; omega.
      replace (n + S i) with (S (n + i)) by omega; eauto.
    + unfold pimpl; pred.
Qed.

Hint Extern 1 ({{_}} progseq (For_ _ _ _ _ _ _) _ >> _) => apply for_ok : prog.
Notation "'For' i < n 'Loopvar' l <- l0 'Continuation' lrx 'Invariant' nocrash 'OnCrash' crashed 'Begin' body 'Rof'" :=
  (For_ (fun i l lrx => body)
        0 n l0
        (fun (_:unit) i l => nocrash%pred)
        (fun (_:unit) => crashed%pred))
  (at level 9, i at level 0, n at level 0, lrx at level 0, l at level 0, l0 at level 0,
   body at level 9).

Notation "'For' i < n 'Ghost' g1 .. g2 'Loopvar' l <- l0 'Continuation' lrx 'Invariant' nocrash 'OnCrash' crashed 'Begin' body 'Rof'" :=
  (For_ (fun i l lrx => body)
        0 n l0
        (pair_args_helper (fun g1 => .. (pair_args_helper (fun g2 (_:unit) =>
         fun i l => nocrash%pred)) .. ))
        (pair_args_helper (fun g1 => .. (pair_args_helper (fun g2 (_:unit) =>
         crashed%pred)) .. )))
  (at level 9, i at level 0, n at level 0,
   g1 binder, g2 binder,
   lrx at level 0, l at level 0, l0 at level 0,
   body at level 9).

Definition read_array a rx :=
  v <- Read a;
  rx v.

Local Hint Extern 1 (diskIs ?m =!=> _) =>
  match goal with
  | [ H: norm_goal (?L ==> ?R) |- _ ] =>
    match R with
    | context[(?a |-> ?v)%pred] =>
      apply diskIs_split; eauto
    end
  end : norm_hint_left.

Local Hint Extern 1 (_ =!=> diskIs ?m) =>
  match goal with
  | [ H: norm_goal (?L ==> ?R) |- _ ] =>
    match L with
    | context[(?a |-> ?v)%pred] =>
      match L with
      | context[diskIs (mem_except m a)] =>
        apply diskIs_merge_except; eauto
      end
    end
  end : norm_hint_right.

Theorem read_array_ok : forall a rx rec,
  {{ exists m v F, diskIs m * F * [[ m @ a |-> v ]]
   * [[ {{ diskIs m * F }} rx v >> rec ]]
   * [[ {{ diskIs m * F }} rec >> rec ]]
  }} read_array a rx >> rec.
Proof.
  unfold read_array.
  hoare.
Qed.

Definition write_array a v rx :=
  Write a v ;;
  rx tt.

Local Hint Extern 1 (_ =!=> diskIs (upd ?m ?a ?v)) =>
  match goal with
  | [ H: norm_goal (?L ==> ?R) |- _ ] =>
    match L with
    | context[(?a |-> ?v')%pred] =>
      match L with
      | context[diskIs (mem_except m a)] =>
        apply diskIs_merge_upd; eauto
      end
    end
  end : norm_hint_right.

Theorem write_array_ok : forall a v rx rec,
  {{ exists m F, diskIs m * F * [[ indomain a m ]]
   * [[ {{ diskIs (upd m a v) * F }} rx tt >> rec ]]
   * [[ {{ diskIs m * F
        \/ diskIs (upd m a v) * F }} rec >> rec ]]
  }} write_array a v rx >> rec.
Proof.
  unfold write_array, indomain.
  hoare.
Qed.

Hint Extern 1 ({{_}} progseq (read_array _) _ >> _) => apply read_array_ok : prog.
Hint Extern 1 ({{_}} progseq (write_array _ _) _ >> _) => apply write_array_ok : prog.
