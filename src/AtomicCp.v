Require Import Prog.
Require Import Log.
Require Import BFile.
Require Import Word.
Require Import Omega.
Require Import BasicProg.
Require Import Bool.
Require Import Pred PredCrash.
Require Import DirName.
Require Import Hoare.
Require Import GenSepN.
Require Import ListPred.
Require Import SepAuto.
Require Import Idempotent.
Require Import Inode.
Require Import List ListUtils.
Require Import Balloc.
Require Import Bytes.
Require Import DirTree.
Require Import Rec.
Require Import Arith.
Require Import Array.
Require Import FSLayout.
Require Import Cache.
Require Import Errno.
Require Import AsyncDisk.
Require Import GroupLog.
Require Import SuperBlock.
Require Import NEList.
Require Import AsyncFS.
Require Import DirUtil.
Require Import String.


Import ListNotations.

Set Implicit Arguments.

(**
 * Atomic copy: create a copy of file [src_fn] in the root directory [the_dnum],
 * with the new file name [dst_fn].
 *
 *)



Module ATOMICCP.

  Definition temp_fn := ".temp"%string.
  
  (** Programs **)

  (* copy an existing src into an existing, empty dst. *)

  Definition copydata T fsxp src_inum dst_inum mscs rx : prog T :=
    let^ (mscs, attr) <-  AFS.file_get_attr fsxp src_inum mscs;
    let^ (mscs, b) <- AFS.read_fblock fsxp src_inum 0 mscs;
    let^ (mscs) <- AFS.update_fblock_d fsxp dst_inum 0 b mscs;
    let^ (mscs, ok) <- AFS.file_set_attr fsxp dst_inum attr mscs;
    let^ (mscs) <- AFS.file_sync fsxp dst_inum mscs;    (* we want a metadata and data sync here *)
    rx ^(mscs, ok).

  Definition copy2temp T fsxp src_inum dst_inum mscs rx : prog T :=
    let^ (mscs, ok) <- AFS.file_truncate fsxp dst_inum 1 mscs;  (* XXX type error when passing sz *)
    If (bool_dec ok true) {
      let^ (mscs, ok) <- copydata fsxp src_inum dst_inum mscs;
      rx ^(mscs, ok)
    } else {
      let^ (mscs) <- AFS.file_sync fsxp dst_inum mscs;    (* do a sync to simplify spec *)
      rx ^(mscs, ok)
    }.

  Definition copy_and_rename T fsxp src_inum dst_inum dst_fn mscs rx : prog T :=
    let^ (mscs, ok) <- copy2temp fsxp src_inum dst_inum mscs;
    match ok with
      | false =>
          rx ^(mscs, false)
      | true =>
        let^ (mscs, ok1) <- AFS.rename fsxp the_dnum [] temp_fn [] dst_fn mscs;
        let^ (mscs) <- AFS.tree_sync fsxp mscs;
        rx ^(mscs, ok1)
    end.

  Definition copy_and_rename_cleanup T fsxp src_inum dst_inum dst_fn mscs rx : prog T :=
    let^ (mscs, ok) <- copy_and_rename fsxp src_inum dst_inum dst_fn mscs;
    match ok with
      | false =>
        let^ (mscs, ok) <- AFS.delete fsxp the_dnum temp_fn mscs;
        (* What if FS.delete fails?? *)
        rx ^(mscs, false)
      | true =>
        rx ^(mscs, true)
    end.

  Definition atomic_cp T fsxp src_inum dst_fn mscs rx : prog T :=
    let^ (mscs, maybe_dst_inum) <- AFS.create fsxp the_dnum temp_fn mscs;
    match maybe_dst_inum with
      | None => rx ^(mscs, false)
      | Some dst_inum =>
        let^ (mscs, ok) <- copy_and_rename_cleanup fsxp src_inum dst_inum dst_fn mscs;
        rx ^(mscs, ok)
    end.

  (** recovery programs **)

  (* atomic_cp recovery: if temp_fn exists, delete it *)
  Definition cleanup {T} fsxp mscs rx : prog T :=
    let^ (mscs, maybe_src_inum) <- AFS.lookup fsxp the_dnum [temp_fn] mscs;
    match maybe_src_inum with
    | None => rx mscs
    | Some (src_inum, isdir) =>
      let^ (mscs, ok) <- AFS.delete fsxp the_dnum temp_fn mscs;
      let^ (mscs) <- AFS.tree_sync fsxp mscs;
      rx mscs
    end.

  (* top-level recovery function: call AFS recover and then atomic_cp's recovery *)
  Definition recover {T} rx : prog T :=
    let^ (mscs, fsxp) <- AFS.recover;
    mscs <- cleanup fsxp mscs;
    rx ^(mscs, fsxp).


  (** Specs and proofs **)

  Lemma arrayN_one: forall V (v:V),
      0 |-> v <=p=> arrayN 0 [v].
  Proof.
    split; cancel.
  Qed.

  Lemma arrayN_ex_one: forall V (l : list V),
      List.length l = 1 ->
      arrayN_ex l 0 <=p=> emp.
  Proof.
    destruct l.
    simpl; intros.
    congruence.
    destruct l.
    simpl. intros.
    unfold arrayN_ex.
    simpl.
    split; cancel.
    simpl. intros.
    congruence.
  Qed.

  Theorem copydata_ok : forall fsxp src_inum tinum mscs,
    {< ds Fm Ftop temp_tree src_fn tfn file tfile v0 t0,
    PRE:hm  LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [tfn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[ src_fn <> tfn ]] *
      [[[ BFILE.BFData file ::: (0 |-> v0) ]]] *
      [[[ BFILE.BFData tfile ::: (0 |-> t0) ]]]
    POST:hm' RET:^(mscs, r)
      exists d tree' f', 
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        ([[ r = false]] * 
         [[ tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum (BFILE.synced_file f')) temp_tree ]]
        \/ 
         [[ r = true ]] *
         [[ tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum (BFILE.synced_file file)) temp_tree ]])
    XCRASH:hm'
      (exists d tree' f', LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (d, nil) hm' *
         [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
         [[ tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum f') temp_tree ]]) \/
      (exists dlist, 
         LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (pushdlist dlist ds) hm' *  
         [[ Forall (fun d => (exists tree' tfile', (Fm * DIRTREE.rep fsxp Ftop tree')%pred (list2nmem d) /\
             tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum tfile') temp_tree)) %type dlist ]])
    >} copydata fsxp src_inum tinum mscs.
  Proof.
    unfold copydata; intros.
    step.
    step.
    step.
    step.
    step.
    prestep. safecancel.
    or_l.
    cancel.
    erewrite update_update_subtree_eq.
    f_equal.
    AFS.xcrash_solve.
    or_l.
    xform_norm; cancel.
    xform_norm; cancel.
    xform_norm; safecancel.
    xform_norm; safecancel.
    admit. (* rewrite LOG.notxn_idempred. *)
    instantiate (1 := d).
    pred_apply; cancel.
    f_equal.
    AFS.xcrash_solve.
    or_l.
    xform_norm; cancel.
    xform_norm; cancel.
    xform_norm; safecancel.
    xform_norm; safecancel.
    admit. (* rewrite LOG.notxn_idempred. *)
    instantiate (1 := x).
    pred_apply; cancel.
    erewrite update_update_subtree_eq.
    f_equal.
    step.
    (* success return *)
    or_r.
    cancel.
    erewrite update_update_subtree_eq.
    erewrite update_update_subtree_eq.
    f_equal.
    f_equal.
    f_equal.
    apply arrayN_one in H5.
    apply list2nmem_array_eq in H5.
    (*
    rewrite arrayN_ex_one in H18.
    rewrite arrayN_one in H18.
    apply emp_star in H18.
    apply list2nmem_array_eq in H18.
    destruct f'.
    destruct file.
    simpl in *.
    rewrite H18.
    rewrite H4.
    f_equal. *)
    admit.
    AFS.xcrash_solve.
    or_r.
    xform_norm; cancel.
    xform_norm; cancel.
    admit.
    admit.
    or_r.
    xform_norm; cancel.
    xform_norm; cancel.
    (* other crash cases *)
  Admitted.

  Hint Extern 1 ({{_}} progseq (copydata _ _ _ _) _) => apply copydata_ok : prog.

  Theorem copy2temp_ok : forall fsxp src_inum tinum mscs,
    {< ds Fm Ftop temp_tree src_fn tfn file tfile v0,
    PRE:hm  LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [tfn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[ src_fn <> tfn ]] *
      [[[ BFILE.BFData file ::: (0 |-> v0) ]]]
    POST:hm' RET:^(mscs, r)
      exists d tree' f', 
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        ([[ r = false]] * 
         [[ tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum (BFILE.synced_file f')) temp_tree ]]
        \/ 
         [[ r = true ]] *
         [[ tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum (BFILE.synced_file file)) temp_tree ]])
    XCRASH:hm'
      (exists d tree' tfile', LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (d, nil) hm' *
         [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
         [[ tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum tfile') temp_tree ]]) \/
      (exists dlist, 
         LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (pushdlist dlist ds) hm' *  
         [[ Forall (fun d => (exists tree' tfile', (Fm * DIRTREE.rep fsxp Ftop tree')%pred (list2nmem d) /\
             tree' = DIRTREE.update_subtree [tfn] (DIRTREE.TreeFile tinum tfile') temp_tree)) %type dlist ]])
    >} copy2temp fsxp src_inum tinum mscs.
  Proof.
    unfold copy2temp; intros.
    step.
    step.
    step.
    step.
    step.
    AFS.xcrash_solve.
    or_l.
    xform_norm. cancel.
    xform_norm. cancel.
    xform_norm. cancel.
    xform_norm. safecancel.
  Admitted.

  Hint Extern 1 ({{_}} progseq (copy2temp _ _ _ _) _) => apply copy2temp_ok : prog.

  Theorem copy_rename_ok : forall  fsxp src_inum tinum dst_fn mscs,
    {< ds Fm Ftop temp_tree src_fn file tfile,
    PRE:hm  LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [temp_fn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[ src_fn <> temp_fn ]] *
      [[ dst_fn <> temp_fn ]] *
      [[ dst_fn <> src_fn ]]
    POST:hm' RET:^(mscs, r)
      exists d tree' pruned subtree temp_dents dstents,
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        (([[r = false ]] *
          (exists f',  
          [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum f') temp_tree ]]))) \/
         ([[r = true ]] *
          [[ temp_tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
          [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn temp_tree ]] *
          [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
          [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
          [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]])
    XCRASH:hm'
      exists dlist,
        [[ Forall (fun d => (exists tree' tfile', (Fm * DIRTREE.rep fsxp Ftop tree')%pred (list2nmem d) /\
             tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum tfile') temp_tree)) %type dlist ]] *
      (
       (* crashed while modifying temp file *)
       LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (pushdlist dlist ds) hm' \/
       (* crashed after modifying temp file and tree_sync and then maybe modifying it again *)
       (exists d dlist', [[dlist = d :: dlist']] * LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (d, dlist') hm') \/
       (* crashed after renaming temp file, might have synced (dlist = nil) or not (dlist != nil) *)
       (exists d tree' pruned subtree temp_dents dstents,
          [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
          [[ temp_tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
          [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn temp_tree ]] *
          [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
          [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
          [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]] *
          LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (d, dlist) hm')
      )
     >} copy_and_rename  fsxp src_inum tinum dst_fn mscs.
  Proof.
    unfold copy_and_rename; intros.
  Admitted.

  (* XXX specs for copy_and_rename_cleanup and atomic_cp *)

  Theorem atomic_cp_recover_ok :
    {< fsxp cs ds,
    PRE:hm
      LOG.after_crash (FSXPLog fsxp) (SB.rep fsxp) ds cs hm (* every ds must have a tree *)
    POST:hm' RET:^(ms, fsxp')
      [[ fsxp' = fsxp ]] * exists d n tree tree' Fm' Fm'' Ftop' Ftop'' temp_dents, 
       [[ n <= List.length (snd ds) ]] *
       LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) ms hm' *
       [[[ d ::: Fm'' * DIRTREE.rep fsxp Ftop'' tree' ]]] *
       [[[ nthd n ds ::: (Fm' * DIRTREE.rep fsxp Ftop' tree) ]]] *
       [[ tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
       [[ tree' = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn tree ]]
    CRASH:hm'
      LOG.after_crash (FSXPLog fsxp) (SB.rep fsxp) ds cs hm'
     >} recover.
  Proof.
  Admitted.

  Theorem atomic_cp_with_recover_ok : forall fsxp src_inum dst_fn mscs,
    {<< ds Fm Ftop temp_tree src_fn file tinum tfile,
    PRE:hm LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [temp_fn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[ src_fn <> temp_fn ]] *
      [[ dst_fn <> temp_fn ]] *
      [[ dst_fn <> src_fn ]]
    POST:hm' RET:^(mscs, r)
      exists d tree' pruned subtree temp_dents dstents,
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        (([[r = false ]] *
          (exists f',  
          [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum f') temp_tree ]]))) \/
         ([[r = true ]] *
          [[ temp_tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
          [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn temp_tree ]] *
          [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
          [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
          [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]])
    REC:hm' RET:^(mscs,fsxp')
     [[ fsxp' = fsxp ]] * exists d n tree tree' Fm' Fm'' Ftop' Ftop'' temp_dents pruned, 
       [[ n <= List.length (snd ds) ]] *
       LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
       [[[ d ::: Fm'' * DIRTREE.rep fsxp Ftop'' tree' ]]] *
       [[[ nthd n ds ::: (Fm' * DIRTREE.rep fsxp Ftop' tree) ]]] *
       [[ tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
       [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn tree ]] *
       ([[ tree' = pruned ]] \/
        exists subtree dstents,
        [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
        [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
        [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]])
    >>} atomic_cp fsxp src_inum dst_fn mscs >> recover.
  Proof.
  Admitted.

End ATOMICCP.
