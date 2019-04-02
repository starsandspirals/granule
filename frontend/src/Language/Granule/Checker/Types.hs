{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Granule.Checker.Types
    (
    -- ** Equality proofs
      equalityProofSubstitution
    , equalityProofConstraints

    -- ** Specification indicators
    , SpecIndicator(..)

    -- ** Equality tests
    , checkEquality

    , requireEqualTypes
    , requireEqualTypesRelatedCoeffects

    , typesAreEqual
    , typesAreEqualWithCheck
    , lTypesAreEqual

    , equalTypesRelatedCoeffects

    , equalTypes
    , lEqualTypes

    , equalTypesWithPolarity
    , lEqualTypesWithPolarity

    , equalTypesWithUniversalSpecialisation

    , joinTypes

    -- *** Instance Equality
    , equalInstances
    , instancesAreEqual

    -- *** Kind Equality
    , equalKinds
    ) where

import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe
import Data.List

import Language.Granule.Checker.Constraints.Compile
import Language.Granule.Checker.Errors
import Language.Granule.Checker.Instance
import Language.Granule.Checker.Kinds
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.SubstitutionContexts
import Language.Granule.Checker.Substitution
import Language.Granule.Checker.Variables

import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type

import Language.Granule.Utils


------------------------------
----- Inequality Reasons -----
------------------------------


type InequalityReason = CheckerError


equalityErr :: (?globals :: Globals, Monad m) => InequalityReason -> m EqualityResult
equalityErr = pure . Left


effectMismatch s ef1 ef2 = equalityErr $
  GradingError (Just s) $
    concat ["Effect mismatch: ", prettyQuoted ef1, " not equal to ", prettyQuoted ef2]


coeffectMismatch s c1 c2 = equalityErr $
  GradingError (Just s) $
    concat ["Coeffect mismatch: ", prettyQuoted c1, " not equal to ", prettyQuoted c2]


unequalSessionTypes s t1 t2 = equalityErr $
  GenericError (Just s) $
    concat ["Session type ", prettyQuoted t1, " is not equal to ", prettyQuoted t2]


sessionsNotDual s t1 t2 = equalityErr $
  GenericError (Just s) $
    concat ["Session type ", prettyQuoted t1, " is not dual to ", prettyQuoted t2]


kindEqualityIsUndefined s k1 k2 t1 t2 = equalityErr $
  KindError (Just s) $
    concat [ "Equality is not defined between kinds "
           , pretty k1, " and ", pretty k2
           , "\t\n from equality "
           , prettyQuoted t2, " and ", prettyQuoted t1 <> " equal."]


contextDoesNotAllowUnification s x y = equalityErr $
  GenericError (Just s) $
    concat [ "Trying to unify ", prettyQuoted x, " and ", prettyQuoted y
           , " but in a context where unification is not allowed."]


cannotUnifyUniversalWithConcrete s n kind t = equalityErr $
  GenericError (Just s) $
    concat [ "Cannot unify a universally quantified type variable "
           , prettyQuoted (TyVar n), " of kind ", prettyQuoted kind
           , " with a concrete type " <> prettyQuoted t]


twoUniversallyQuantifiedVariablesAreUnequal s v1 v2 = equalityErr $
  GenericError (Just s) $
    concat [ quoteTyVar v1, " and ", quoteTyVar v2
           , " are both universally quantified, and thus cannot be equal."]
  where quoteTyVar = prettyQuoted . TyVar


nonUnifiable s t1 t2 = equalityErr $
  let addendum = if pretty t1 == pretty t2 then " coming from a different binding" else ""
  in GenericError (Just s) $
       concat ["Type ", prettyQuoted t1, " is not unifiable with the type ", prettyQuoted t2, addendum]


-- | Generic inequality for when a more specific reason is not known.
unequalNotSpecified s v1 v2 = equalityErr $
  GenericError (Just s) $
    concat [ quoteTyVar v1, " and ", quoteTyVar v2
           , " are not equal."]
  where quoteTyVar = prettyQuoted . TyVar


-- | Generic inequality for when a more specific reason is not known.
unequalKinds s k1 k2 = equalityErr $
  KindError (Just s) $
    concat [ prettyQuoted k1, " and ", prettyQuoted k2
           , " are not equal."]


cannotBeBoth s v s1 s2 =
  let t1 = fromSubst s1
      t2 = fromSubst s2
  in equalityErr $ GenericError (Just s) $
     concat [ prettyQuoted v, " cannot be equal to both ", t1, " and ", t2 ]
  where fromSubst (SubstT t) = prettyQuoted t
        fromSubst (SubstK k) = prettyQuoted k
        fromSubst (SubstC c) = prettyQuoted c
        fromSubst (SubstE e) = prettyQuoted e


-- | Attempt to unify a non-type variable with a type.
illKindedUnifyVar sp (v, k1) (t, k2) = equalityErr $
   KindError (Just sp) $
     concat [ "Trying to unify ", prettyQuoted v, " of kind ", prettyQuoted k1
            , " with a type ", prettyQuoted t, " of kind ", prettyQuoted k2 ]


-- | Test @x@ and @y@ for boolean equality. If they are
-- | equal then return a trivial proof of equality, otherwise
-- | use @desc@ to provide a descriptive reason for inequality.
directEqualityTest desc s x y =
  if x == y then trivialEquality else equalityErr $
  GenericError (Just s) $
    concat [desc, " ", prettyQuoted x, " and ", prettyQuoted y
           , " are not equal."]


miscErr :: (?globals :: Globals) => CheckerError -> MaybeT Checker EqualityResult
miscErr = equalityErr


-- | Infer a kind for the given type (promoting any errors to the inequality reason),
-- | and run the prover on the kind.
withInferredKind :: (?globals :: Globals) => Span -> Type
                 -> (Kind -> MaybeT Checker EqualityResult)
                 -> MaybeT Checker EqualityResult
withInferredKind sp t c =
  inferKindOfTypeSafe sp t >>= either miscErr c


-- | Execute the prover with the most general unifier of
-- | the two coeffects as an argument.
withMguCoeffectTypes :: (?globals :: Globals) => Span -> Coeffect -> Coeffect
                     -> (Type -> MaybeT Checker EqualityResult)
                     -> MaybeT Checker EqualityResult
withMguCoeffectTypes sp c c' pf =
  mguCoeffectTypesSafe sp c c' >>= either miscErr pf


--------------------------
----- Equality types -----
--------------------------


-- | A proof of equality.
type EqualityProof = ([Constraint], Substitution)


-- | Get the substitution from a proof of equality.
equalityProofSubstitution :: EqualityProof -> Substitution
equalityProofSubstitution = snd


-- | Get the constraints from a proof of equality.
equalityProofConstraints :: EqualityProof -> [Constraint]
equalityProofConstraints = fst


type EqualityResult = Either InequalityReason EqualityProof


-- | True if the check for equality was successful.
equalityResultIsSuccess :: EqualityResult -> Bool
equalityResultIsSuccess = either (const False) (const True)


-- | A proof of a trivial equality ('x' and 'y' are equal because we say so).
trivialEquality' :: EqualityResult
trivialEquality' = pure ([], [])


-- | Equality where nothing needs to be done.
trivialEquality :: MaybeT Checker EqualityResult
trivialEquality = pure trivialEquality'


-- | Attempt to prove equality using the result of a previous proof.
eqSubproof :: (Monad m) => EqualityResult -> (EqualityProof -> m (Either InequalityReason a)) -> m (Either InequalityReason a)
eqSubproof e f = either (pure . Left) f e


-- | Require that two proofs of equality hold, and if so, combine them.
combinedEqualities :: (?globals :: Globals) => Span -> EqualityResult -> EqualityResult -> MaybeT Checker EqualityResult
combinedEqualities s e1 e2 =
  eqSubproof e1 $ \eq1res -> do
    eqSubproof e2 $ \eq2res -> do
      let u1 = equalityProofSubstitution eq1res
          u2 = equalityProofSubstitution eq2res
          cs = equalityProofConstraints eq1res
               <> equalityProofConstraints eq2res
      uf <- combineSubstitutionsSafe s u1 u2
      case uf of
        Left (v, s1, s2) -> cannotBeBoth s v s1 s2
        Right cuf -> pure . pure $ (cs, cuf)


-- | An equality under the given proof.
equalWith :: EqualityProof -> EqualityResult
equalWith = Right


-- | Update the state with information from the equality proof.
enactEquality :: (?globals :: Globals) => Type -> EqualityProof -> MaybeT Checker ()
enactEquality t eqres = do
  let u = equalityProofSubstitution eqres
      cs = equalityProofConstraints eqres
  substitute u t
  mapM_ addConstraint cs


-- | Check for equality, and update the checker state.
checkEquality :: (?globals :: Globals)
  => (Type -> MaybeT Checker EqualityResult) -> Type -> MaybeT Checker EqualityResult
checkEquality eqm t = do
  eq <- eqm t
  case eq of
    Right eqres -> enactEquality t eqres
    Left _ -> pure ()
  pure eq


-- | Require that an equality holds, and perform a unification
-- | to reflect this equality in the checker.
requireEqualityResult :: (?globals :: Globals)
  => Type -> MaybeT Checker EqualityResult -> MaybeT Checker EqualityProof
requireEqualityResult t = (>>= either halt (\r -> enactEquality t r >> pure r))


---------------------------------
----- Bulk of equality code -----
---------------------------------


-- | True if the two types are equal.
typesAreEqual :: (?globals :: Globals) => Span -> Type -> Type -> MaybeT Checker Bool
typesAreEqual s t1 t2 =
  fmap equalityResultIsSuccess $ equalTypes s t1 t2


-- | True if the two types are equal.
typesAreEqualWithCheck :: (?globals :: Globals) => Span -> Type -> Type -> MaybeT Checker Bool
typesAreEqualWithCheck s t1 t2 =
  fmap equalityResultIsSuccess $ checkEquality (equalTypes s t1) t2


lTypesAreEqual :: (?globals :: Globals) => Span -> Type -> Type -> MaybeT Checker Bool
lTypesAreEqual s t1 t2 = fmap (either (const False) (const True)) $ lEqualTypes s t1 t2


requireEqualTypes :: (?globals :: Globals)
  => Span -> Type -> Type -> MaybeT Checker EqualityProof
requireEqualTypes s t1 t2 =
    requireEqualityResult t2 $ equalTypes s t1 t2


requireEqualTypesRelatedCoeffects :: (?globals :: Globals)
  => Span
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -> SpecIndicator
  -> Type
  -> Type
  -> MaybeT Checker EqualityProof
requireEqualTypesRelatedCoeffects s rel spec t1 t2 =
    requireEqualityResult t2 $ equalTypesRelatedCoeffects s rel spec t1 t2


lEqualTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator ->Type -> Type -> MaybeT Checker EqualityResult
lEqualTypesWithPolarity s pol = equalTypesRelatedCoeffects s ApproximatedBy pol


equalTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator -> Type -> Type -> MaybeT Checker EqualityResult
equalTypesWithPolarity s pol = equalTypesRelatedCoeffects s Eq pol


lEqualTypes :: (?globals :: Globals)
  => Span -> Type -> Type -> MaybeT Checker EqualityResult
lEqualTypes s = equalTypesRelatedCoeffects s ApproximatedBy SndIsSpec


equalTypes :: (?globals :: Globals)
  => Span -> Type -> Type -> MaybeT Checker EqualityResult
equalTypes s = equalTypesRelatedCoeffects s Eq SndIsSpec


equalTypesWithUniversalSpecialisation :: (?globals :: Globals)
  => Span -> Type -> Type -> MaybeT Checker EqualityResult
equalTypesWithUniversalSpecialisation s =
  equalTypesRelatedCoeffects s Eq SndIsSpec


data SpecIndicator = FstIsSpec | SndIsSpec | PatternCtxt
  deriving (Eq, Show)

flipIndicator FstIsSpec = SndIsSpec
flipIndicator SndIsSpec = FstIsSpec
flipIndicator PatternCtxt = PatternCtxt

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and a unifier
      Polarity indicates which -}
equalTypesRelatedCoeffects :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -- Indicates whether the first type or second type is a specification
  -> SpecIndicator
  -> Type
  -> Type
  -> MaybeT Checker EqualityResult
equalTypesRelatedCoeffects s rel sp (FunTy t1 t2) (FunTy t1' t2') = do
  -- contravariant position (always approximate)
  eq1 <- equalTypesRelatedCoeffects s ApproximatedBy (flipIndicator sp) t1' t1
  eq2 <- eqSubproof eq1 $ \eqres -> do
           let u1 = equalityProofSubstitution eqres
           -- covariant position (depends: is not always over approximated)
           t2 <- substitute u1 t2
           t2' <- substitute u1 t2'
           equalTypesRelatedCoeffects s rel sp t2 t2'
  combinedEqualities s eq1 eq2

equalTypesRelatedCoeffects s _ _ (TyCon con1) (TyCon con2) =
  directEqualityTest "Type constructors" s con1 con2

-- THE FOLLOWING FOUR CASES ARE TEMPORARY UNTIL WE MAKE 'Effect' RICHER

-- Over approximation by 'IO' "monad"
equalTypesRelatedCoeffects s rel sp (Diamond ef t1) (Diamond ["IO"] t2)
    = equalTypesRelatedCoeffects s rel sp t1 t2

-- Under approximation by 'IO' "monad"
equalTypesRelatedCoeffects s rel sp (Diamond ["IO"] t1) (Diamond ef t2)
    = equalTypesRelatedCoeffects s rel sp t1 t2

-- Over approximation by 'Session' "monad"
equalTypesRelatedCoeffects s rel sp (Diamond ef t1) (Diamond ["Session"] t2)
    | "Com" `elem` ef || null ef
      = equalTypesRelatedCoeffects s rel sp t1 t2

-- Under approximation by 'Session' "monad"
equalTypesRelatedCoeffects s rel sp (Diamond ["Session"] t1) (Diamond ef t2)
    | "Com" `elem` ef || null ef
      = equalTypesRelatedCoeffects s rel sp t1 t2

equalTypesRelatedCoeffects s rel sp (Diamond ef1 t1) (Diamond ef2 t2) = do
  if ( ef1 == ef2
     -- Effect approximation
     || ef1 `isPrefixOf` ef2
     -- Communication effect analysis is idempotent
     || (nub ef1 == ["Com"] && nub ef2 == ["Com"]))
  then equalTypesRelatedCoeffects s rel sp t1 t2
  else effectMismatch s ef1 ef2

equalTypesRelatedCoeffects s rel sp x@(Box c t) y@(Box c' t') = do
  -- Debugging messages
  debugM "equalTypesRelatedCoeffects (pretty)" $ pretty c <> " == " <> pretty c'
  debugM "equalTypesRelatedCoeffects (show)" $ "[ " <> show c <> " , " <> show c' <> "]"
  -- Unify the coeffect kinds of the two coeffects
  withMguCoeffectTypes s c c' $ \kind -> do
    eq1 <- case sp of
      SndIsSpec -> do
        pure $ equalWith ([rel s c c' kind], [])
      FstIsSpec -> do
        pure $ equalWith ([rel s c' c kind], [])
      _ -> contextDoesNotAllowUnification s x y
    eq2 <- equalTypesRelatedCoeffects s rel sp t t'
    combinedEqualities s eq1 eq2

equalTypesRelatedCoeffects s rel sp (TyCoeffect c1) (TyCoeffect c2) =
  if (c1 == c2) then trivialEquality else coeffectMismatch s c1 c2

equalTypesRelatedCoeffects s _ _ (TyVar n) (TyVar m) | n == m = do
  checkerState <- get
  case lookup n (tyVarContext checkerState) of
    Just _ -> trivialEquality
    Nothing -> miscErr $ UnboundVariableError (Just s) ("Type variable " <> pretty n)

equalTypesRelatedCoeffects s _ sp (TyVar n) (TyVar m) = do
  checkerState <- get
  debugM "variable equality" $ pretty n <> " ~ " <> pretty m <> " where "
                            <> pretty (lookup n (tyVarContext checkerState)) <> " and "
                            <> pretty (lookup m (tyVarContext checkerState))

  case (lookup n (tyVarContext checkerState), lookup m (tyVarContext checkerState)) of

    (Just (_, ForallQ), Just (_, ForallQ)) ->
        twoUniversallyQuantifiedVariablesAreUnequal s n m

    -- We can unify a universal a dependently bound universal
    (Just (k1, ForallQ), Just (k2, BoundQ)) ->
      tyVarConstraint (k1, n) (k2, m)

    (Just (k1, BoundQ), Just (k2, ForallQ)) ->
      tyVarConstraint (k2, m) (k1, n)


    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- But we can unify a forall and an instance
    (Just (k1, InstanceQ), Just (k2, ForallQ)) ->
        tyVarConstraint (k2, m) (k1, n)

    -- But we can unify a forall and an instance
    (Just (k1, ForallQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    (t1, t2) -> error $ pretty s <> "-" <> show sp <> "\n"
              <> pretty n <> " : " <> show t1
              <> "\n" <> pretty m <> " : " <> show t2
  where
    tyVarConstraint (k1, n) (k2, m) = do
      case k1 `joinKind` k2 of
        Just (KPromote (TyCon kc)) -> do

          withInferredKind s (TyCon kc) $ \k -> do
            -- Create solver vars for coeffects
            let constrs = case k of
                            KCoeffect -> [Eq s (CVar n) (CVar m) (TyCon kc)]
                            _ -> []
            pure $ equalWith (constrs, [(m, SubstT $ TyVar n)])
        Just _ ->
          pure $ equalWith ([], [(m, SubstT $ TyVar n)])
        Nothing -> unequalNotSpecified s n m


-- Duality is idempotent (left)
equalTypesRelatedCoeffects s rel sp (TyApp (TyCon d') (TyApp (TyCon d) t)) t'
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffects s rel sp t t'

-- Duality is idempotent (right)
equalTypesRelatedCoeffects s rel sp t (TyApp (TyCon d') (TyApp (TyCon d) t'))
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffects s rel sp t t'

equalTypesRelatedCoeffects s rel sp (TyVar n) t = do
  checkerState <- get
  debugM "Types.equalTypesRelatedCoeffects on TyVar"
          $ "span: " <> show s
          <> "\nTyVar: " <> show n <> " with " <> show (lookup n (tyVarContext checkerState))
          <> "\ntype: " <> show t <> "\nspec indicator: " <> show sp
  case lookup n (tyVarContext checkerState) of
    -- We can unify an instance with a concrete type
    (Just (k1, q)) | (q == BoundQ) || (q == InstanceQ && sp /= PatternCtxt) -> do
      withInferredKind s t $ \k2 ->
        case k1 `joinKind` k2 of
          Nothing -> illKindedUnifyVar s (n, k1) (t, k2)

          -- If the kind is Nat, then create a solver constraint
          Just (KPromote (TyCon (internalName -> "Nat"))) -> do
            nat <- compileNatKindedTypeToCoeffect s t
            pure $ equalWith ([Eq s (CVar n) nat (TyCon $ mkId "Nat")], [(n, SubstT t)])

          Just _ -> pure $ equalWith ([], [(n, SubstT t)])

    -- NEW

    (Just (k1, ForallQ)) -> do
       -- Infer the kind of this equality
       withInferredKind s t $ \k2 -> do
         let kind = k1 `joinKind` k2

         -- If the kind if nat then set up and equation as there might be a
         -- pausible equation involving the quantified variable
         if (kind == Just (KPromote (TyCon (Id "Nat" "Nat"))))
           then do
             c1 <- compileNatKindedTypeToCoeffect s (TyVar n)
             c2 <- compileNatKindedTypeToCoeffect s t
             pure $ equalWith ([Eq s c1 c2 (TyCon $ mkId "Nat")], [(n, SubstT t)])

           else cannotUnifyUniversalWithConcrete s n kind t

    (Just (_, InstanceQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    (Just (_, BoundQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    Nothing -> miscErr $ UnboundVariableError (Just s) (pretty n <?> ("Types.equalTypesRelatedCoeffects: " <> show (tyVarContext checkerState)))


equalTypesRelatedCoeffects s rel sp t (TyVar n) =
  equalTypesRelatedCoeffects s rel (flipIndicator sp) (TyVar n) t

-- Do duality check (left) [special case of TyApp rule]
equalTypesRelatedCoeffects s rel sp (TyApp (TyCon d) t) t'
  | internalName d == "Dual" = isDualSession s rel sp t t'

equalTypesRelatedCoeffects s rel sp t (TyApp (TyCon d) t')
  | internalName d == "Dual" = isDualSession s rel sp t t'

-- Equality on type application
equalTypesRelatedCoeffects s rel sp (TyApp t1 t2) (TyApp t1' t2') = do
  eq1 <- equalTypesRelatedCoeffects s rel sp t1 t1'
  eq2 <- eqSubproof eq1 (\eqres -> do
           let u1 = equalityProofSubstitution eqres
           t2 <- substitute u1 t2
           t2' <- substitute u1 t2'
           equalTypesRelatedCoeffects s rel sp t2 t2')
  combinedEqualities s eq1 eq2


equalTypesRelatedCoeffects s rel _ t1 t2 = do
  debugM "equalTypesRelatedCoeffects" $ "called on: " <> show t1 <> "\nand:\n" <> show t2
  equalOtherKindedTypesGeneric s t1 t2

{- | Equality on other types (e.g. Nat and Session members) -}
equalOtherKindedTypesGeneric :: (?globals :: Globals)
    => Span
    -> Type
    -> Type
    -> MaybeT Checker EqualityResult
equalOtherKindedTypesGeneric s t1 t2 = do
  withInferredKind s t1 $ \k1 -> withInferredKind s t2 $ \k2 ->
    if k1 == k2 then
      case k1 of
        KPromote (TyCon (internalName -> "Nat")) -> do
          c1 <- compileNatKindedTypeToCoeffect s t1
          c2 <- compileNatKindedTypeToCoeffect s t2
          pure $ equalWith ([Eq s c1 c2 (TyCon $ mkId "Nat")], [])

        KPromote (TyCon (internalName -> "Protocol")) ->
          sessionInequality s t1 t2

        KType -> nonUnifiable s t1 t2

        _ -> kindEqualityIsUndefined s k1 k2 t1 t2
    else nonUnifiable s t1 t2

-- Essentially use to report better error messages when two session type
-- are not equality
sessionInequality :: (?globals :: Globals)
    => Span -> Type -> Type -> MaybeT Checker EqualityResult
sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Send" && internalName c' == "Send" = do
  equalTypes s t t'

sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Recv" && internalName c' == "Recv" = do
  equalTypes s t t'

sessionInequality s (TyCon c) (TyCon c')
  | internalName c == "End" && internalName c' == "End" =
  trivialEquality

sessionInequality s t1 t2 = unequalSessionTypes s t1 t2

isDualSession :: (?globals :: Globals)
    => Span
       -- Explain how coeffects should be related by a solver constraint
    -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
    -- Indicates whether the first type or second type is a specification
    -> SpecIndicator
    -> Type
    -> Type
    -> MaybeT Checker EqualityResult
isDualSession sp rel ind (TyApp (TyApp (TyCon c) t) s) (TyApp (TyApp (TyCon c') t') s')
  |  (internalName c == "Send" && internalName c' == "Recv")
  || (internalName c == "Recv" && internalName c' == "Send") = do
  eq1 <- equalTypesRelatedCoeffects sp rel ind t t'
  eq2 <- isDualSession sp rel ind s s'
  combinedEqualities sp eq1 eq2

isDualSession _ _ _ (TyCon c) (TyCon c')
  | internalName c == "End" && internalName c' == "End" =
  trivialEquality

isDualSession sp rel ind t (TyVar v) =
  equalTypesRelatedCoeffects sp rel ind (TyApp (TyCon $ mkId "Dual") t) (TyVar v)

isDualSession sp rel ind (TyVar v) t =
  equalTypesRelatedCoeffects sp rel ind (TyVar v) (TyApp (TyCon $ mkId "Dual") t)

isDualSession sp _ _ t1 t2 = sessionsNotDual sp t1 t2


-- Essentially equality on types but join on any coeffects
joinTypes :: (?globals :: Globals) => Span -> Type -> Type -> MaybeT Checker Type

joinTypes s t t' | t == t' = return t

joinTypes s (FunTy t1 t2) (FunTy t1' t2') = do
  t1j <- joinTypes s t1' t1 -- contravariance
  t2j <- joinTypes s t2 t2'
  return (FunTy t1j t2j)

joinTypes _ (TyCon t) (TyCon t') | t == t' = return (TyCon t)

joinTypes s (Diamond ef t) (Diamond ef' t') = do
  tj <- joinTypes s t t'
  if ef `isPrefixOf` ef'
    then return (Diamond ef' tj)
    else
      if ef' `isPrefixOf` ef
      then return (Diamond ef tj)
      else effectMismatch s ef ef' >>= either halt (pure . const t')

joinTypes s (Box c t) (Box c' t') = do
  coeffTy <- mguCoeffectTypes s c c'
  -- Create a fresh coeffect variable
  topVar <- freshTyVarInContext (mkId "") (promoteTypeToKind coeffTy)
  -- Unify the two coeffects into one
  addConstraint (ApproximatedBy s c  (CVar topVar) coeffTy)
  addConstraint (ApproximatedBy s c' (CVar topVar) coeffTy)
  tUpper <- joinTypes s t t'
  return $ Box (CVar topVar) tUpper

joinTypes s (TyInt n) (TyVar m) = do
  -- Create a fresh coeffect variable
  let ty = TyCon $ mkId "Nat"
  var <- freshTyVarInContext m (KPromote ty)
  -- Unify the two coeffects into one
  addConstraint (Eq s (CNat n) (CVar var) ty)
  return $ TyInt n

joinTypes s (TyVar n) (TyInt m) = joinTypes s (TyInt m) (TyVar n)

joinTypes s (TyVar n) (TyVar m) = do
  -- Create fresh variables for the two tyint variables
  -- TODO: how do we know they are tyints? Looks suspicious
  --let kind = TyCon $ mkId "Nat"
  --nvar <- freshTyVarInContext n kind
  --mvar <- freshTyVarInContext m kind
  -- Unify the two variables into one
  --addConstraint (ApproximatedBy s (CVar nvar) (CVar mvar) kind)
  --return $ TyVar n
  -- TODO: FIX. The above can't be right.
  error $ "Trying to join two type variables: " ++ pretty n ++ " and " ++ pretty m

joinTypes s (TyApp t1 t2) (TyApp t1' t2') = do
  t1'' <- joinTypes s t1 t1'
  t2'' <- joinTypes s t2 t2'
  return (TyApp t1'' t2'')

joinTypes s t1 t2 = do
  halt $ GenericError (Just s)
    $ "Type '" <> pretty t1 <> "' and '"
               <> pretty t2 <> "' have no upper bound"


----------------------------
----- Instance Helpers -----
----------------------------


-- | Prove or disprove the equality of two instances in the current context.
equalInstances :: (?globals :: Globals) => Span -> Inst -> Inst -> MaybeT Checker EqualityResult
equalInstances sp instx insty =
  let ts1 = instParams instx
      ts2 = instParams insty
  in foldM (\eq (t1,t2) -> equalTypes sp t1 t2 >>= combinedEqualities sp eq) trivialEquality' (zip ts1 ts2)


-- TODO: update this (instancesAreEqual) to use 'solveConstraintsSafe' to
-- determine if two instances are equal after solving.
-- "instancesAreEqual'" (in Checker) should then be removed
--      - GuiltyDolphin (2019-03-17)

-- | True if the two instances can be proven to be equal in the current context.
instancesAreEqual :: (?globals :: Globals) => Span -> Inst -> Inst -> MaybeT Checker Bool
instancesAreEqual s t1 t2 = fmap equalityResultIsSuccess $ equalInstances s t1 t2


-------------------
-- Kind equality --
-------------------


-- | Determine whether two kinds are equal, and under what proof.
-- |
-- | This is presently rather simplistic, and allows poly-kinds to
-- | unify with anything.
equalKinds :: (?globals :: Globals) => Span -> Kind -> Kind -> MaybeT Checker EqualityResult
equalKinds _ k1 k2 | k1 == k2 = trivialEquality
equalKinds _ (KVar v) k = pure $ equalWith ([], [(v, SubstK k)])
equalKinds _ k (KVar v) = pure $ equalWith ([], [(v, SubstK k)])
equalKinds _ KType KType = trivialEquality
equalKinds sp (KFun k1 k1Arg) (KFun k2 k2Arg) = do
  pf1 <- equalKinds sp k1 k2
  pf2 <- equalKinds sp k1Arg k2Arg
  combinedEqualities sp pf1 pf2
equalKinds sp k1 k2 = unequalKinds sp k1 k2
