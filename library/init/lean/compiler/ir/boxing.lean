/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import init.control.estate
import init.control.reader
import init.lean.compiler.ir.basic
import init.lean.compiler.ir.compilerm
import init.lean.compiler.ir.freevars

namespace Lean
namespace IR
namespace ExplicitBoxing
/-
Add explicit boxing and unboxing instructions.
Recall that the Lean to λ_pure compiler produces code without these instructions.

Assumptions:
- This transformation is applied before explicit RC instructions (`inc`, `dec` and `release`) are inserted.
- This transformation is applied before `FnBody.case` has been simplified and `Alt.default` is used.
  Reason: if there is no `Alt.default` branch, then we can decide whether `x` at `FnBody.case x alts` is an
  enumeration type by simply inspecting the `CtorInfo` values at `alts`.
- This transformation is applied before lower level optimizations are applied which use
  `Expr.isShared`, `Expr.isTaggedPtr`, and `FnBody.set`.
- This transformation is applied after `reset` and `reuse` instructions have been added.
  Reason: `resetreuse.lean` ignores `box` and `unbox` instructions.
-/

/- Infer scrutinee type using `case` alternatives.
   This can be done whenever `alts` does not contain an `Alt.default _` value. -/
def getScrutineeType (alts : Array Alt) : IRType :=
let isScalar :=
   alts.size > 1 && -- Recall that we encode Unit and PUnit using `object`.
   alts.all (λ alt, match alt with
    | Alt.ctor c _  := c.isScalar
    | Alt.default _ := false) in
match isScalar with
| false := IRType.object
| true  :=
  let n := alts.size in
  if n < 256 then IRType.uint8
  else if n < 65536 then IRType.uint16
  else if n < 4294967296 then IRType.uint32
  else IRType.object -- in practice this should be unreachable

def eqvTypes (t₁ t₂ : IRType) : Bool :=
(t₁.isScalar == t₂.isScalar) && (!t₁.isScalar || t₁ == t₂)

structure BoxingContext :=
(localCtx : LocalContext := {}) (resultType : IRType := IRType.irrelevant) (decls : Array Decl) (env : Environment)

abbrev M := ReaderT BoxingContext (StateT Index Id)

def mkFresh : M VarId :=
do idx ← getModify (+1),
   pure { idx := idx }

def localContext : M LocalContext := BoxingContext.localCtx <$> read

def resultType : M IRType := BoxingContext.resultType <$> read

def getVarType (x : VarId) : M IRType :=
do localCtx ← localContext,
   match localCtx.getType x with
   | some t := pure t
   | none   := pure IRType.object -- unreachable, we assume the code is well formed
def getJPParams (j : JoinPointId) : M (Array Param) :=
do localCtx ← localContext,
   match localCtx.getJPParams j with
   | some ys := pure ys
   | none    := pure Array.empty -- unreachable, we assume the code is well formed
def getDecl (fid : FunId) : M Decl :=
do ctx ← read,
   match findEnvDecl' ctx.env fid ctx.decls with
   | some decl := pure decl
   | none      := pure (default _) -- unreachable if well-formed

@[inline] def withParams {α : Type} (xs : Array Param) (k : M α) : M α :=
adaptReader (λ ctx : BoxingContext, { localCtx := ctx.localCtx.addParams xs, .. ctx }) k

@[inline] def withVDecl {α : Type} (x : VarId) (ty : IRType) (v : Expr) (k : M α) : M α :=
adaptReader (λ ctx : BoxingContext, { localCtx := ctx.localCtx.addLocal x ty v, .. ctx }) k

@[inline] def withJDecl {α : Type} (j : JoinPointId) (xs : Array Param) (v : FnBody) (k : M α) : M α :=
adaptReader (λ ctx : BoxingContext, { localCtx := ctx.localCtx.addJP j xs v, .. ctx }) k

/- Auxiliary function used by castVarIfNeeded.
   It is used when the expected type does not match `xType`.
   If `xType` is scalar, then we need to "box" it. Otherwise, we need to "unbox" it. -/
def mkCast (x : VarId) (xType : IRType) : Expr :=
if xType.isScalar then Expr.box xType x else Expr.unbox x

@[inline] def castVarIfNeeded (x : VarId) (expected : IRType) (k : VarId → M FnBody) : M FnBody :=
do xType ← getVarType x,
   if eqvTypes xType expected then k x
   else do
     y ← mkFresh,
     let v := mkCast x xType,
     FnBody.vdecl y expected v <$> k y

@[inline] def castArgIfNeeded (x : Arg) (expected : IRType) (k : Arg → M FnBody) : M FnBody :=
match x with
| Arg.var x := castVarIfNeeded x expected (λ x, k (Arg.var x))
| _         := k x

@[specialize] def castArgsIfNeededAux (xs : Array Arg) (typeFromIdx : Nat → IRType) : M (Array Arg × Array FnBody) :=
xs.miterate (Array.empty, Array.empty) $ λ i (x : Arg) (r : Array Arg × Array FnBody),
  let expected := typeFromIdx i.val in
  let (xs, bs) := r in
  match x with
  | Arg.irrelevant := pure (xs.push x, bs)
  | Arg.var x := do
    xType ← getVarType x,
    if eqvTypes xType expected then pure (xs.push (Arg.var x), bs)
    else do
      y ← mkFresh,
      let v := mkCast x xType,
      let b := FnBody.vdecl y expected v FnBody.nil,
      pure (xs.push (Arg.var y), bs.push b)

@[inline] def castArgsIfNeeded (xs : Array Arg) (ps : Array Param) (k : Array Arg → M FnBody) : M FnBody :=
do (ys, bs) ← castArgsIfNeededAux xs (λ i, (ps.get i).ty),
   b ← k ys,
   pure (reshape bs b)

@[inline] def boxArgsIfNeeded (xs : Array Arg) (k : Array Arg → M FnBody) : M FnBody :=
do (ys, bs) ← castArgsIfNeededAux xs (λ _, IRType.object),
   b ← k ys,
   pure (reshape bs b)

def unboxResultIfNeeded (x : VarId) (ty : IRType) (e : Expr) (b : FnBody) : M FnBody :=
if ty.isScalar then do
  y ← mkFresh,
  pure $ FnBody.vdecl y IRType.object e (FnBody.vdecl x ty (Expr.unbox y) b)
else
  pure $ FnBody.vdecl x ty e b

def castResultIfNeeded (x : VarId) (ty : IRType) (e : Expr) (eType : IRType) (b : FnBody) : M FnBody :=
if eqvTypes ty eType then pure $ FnBody.vdecl x ty e b
else do
  y ← mkFresh,
  pure $ FnBody.vdecl y eType e (FnBody.vdecl x ty (mkCast y eType) b)

def visitVDeclExpr (x : VarId) (ty : IRType) (e : Expr) (b : FnBody) : M FnBody :=
match e with
| Expr.ctor c ys :=
  if c.isScalar && ty.isScalar then
    pure $ FnBody.vdecl x ty (Expr.lit (LitVal.num c.cidx)) b
  else
    boxArgsIfNeeded ys $ λ ys, pure $ FnBody.vdecl x ty (Expr.ctor c ys) b
| Expr.reuse w c u ys :=
  boxArgsIfNeeded ys $ λ ys, pure $ FnBody.vdecl x ty (Expr.reuse w c u ys) b
| Expr.fap f ys := do
  decl ← getDecl f,
  castArgsIfNeeded ys decl.params $ λ ys,
  castResultIfNeeded x ty (Expr.fap f ys) decl.resultType b
| Expr.pap f ys := do
  decl ← getDecl f,
  boxArgsIfNeeded ys $ λ ys, pure $ FnBody.vdecl x ty (Expr.pap f ys) b
| Expr.ap f ys :=
  boxArgsIfNeeded ys $ λ ys,
  unboxResultIfNeeded x ty (Expr.ap f ys) b
| other :=
  pure $ FnBody.vdecl x ty e b

partial def visitFnBody : FnBody → M FnBody
| (FnBody.vdecl x t v b)     := do
  b ← withVDecl x t v (visitFnBody b),
  visitVDeclExpr x t v b
| (FnBody.jdecl j xs v b)    := do
  v ← withParams xs (visitFnBody v),
  b ← withJDecl j xs v (visitFnBody b),
  pure $ FnBody.jdecl j xs v b
| (FnBody.uset x i y b)      := do
  b ← visitFnBody b,
  castVarIfNeeded y IRType.usize $ λ y,
    pure $ FnBody.uset x i y b
| (FnBody.sset x i o y ty b) := do
  b ← visitFnBody b,
  castVarIfNeeded y ty $ λ y,
    pure $ FnBody.sset x i o y ty b
| (FnBody.mdata d b)         :=
  FnBody.mdata d <$> visitFnBody b
| (FnBody.case tid x alts)   := do
  let expected := getScrutineeType alts,
  alts ← alts.hmmap $ λ alt, alt.mmodifyBody visitFnBody,
  castVarIfNeeded x expected $ λ x,
    pure $ FnBody.case tid x alts
| (FnBody.ret x)             := do
  expected ← resultType,
  castArgIfNeeded x expected (λ x, pure $ FnBody.ret x)
| (FnBody.jmp j ys)          := do
  ps ← getJPParams j,
  castArgsIfNeeded ys ps (λ ys, pure $ FnBody.jmp j ys)
| other                      :=
  pure other

def run (env : Environment) (decls : Array Decl) : Array Decl :=
let ctx : BoxingContext := { decls := decls, env := env } in
decls.map (λ decl, match decl with
  | Decl.fdecl f xs t b :=
    let nextIdx := decl.maxIndex + 1 in
    let b := (withParams xs (visitFnBody b) { resultType := t, .. ctx }).run' nextIdx in
    Decl.fdecl f xs t b
  | d := d)

end ExplicitBoxing

def explicitBoxing (decls : Array Decl) : CompilerM (Array Decl) :=
do env ← getEnv,
   pure $ ExplicitBoxing.run env decls

end IR
end Lean
