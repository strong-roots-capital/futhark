{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Trustworthy #-}

module Futhark.Internalise.TypesValues
  ( -- * Internalising types
    internaliseReturnType,
    internaliseLambdaReturnType,
    internaliseEntryReturnType,
    internaliseType,
    internaliseParamTypes,
    internaliseLoopParamType,
    internalisePrimType,
    internalisedTypeSize,
    internaliseSumType,

    -- * Internalising values
    internalisePrimValue,
  )
where

import Control.Monad.Reader
import Control.Monad.State
import Data.List (delete, find, foldl')
import qualified Data.Map.Strict as M
import Data.Maybe
import Futhark.IR.SOACS as I
import Futhark.Internalise.Monad
import qualified Language.Futhark as E

internaliseUniqueness :: E.Uniqueness -> I.Uniqueness
internaliseUniqueness E.Nonunique = I.Nonunique
internaliseUniqueness E.Unique = I.Unique

type TypeState = Int

newtype InternaliseTypeM a
  = InternaliseTypeM (StateT TypeState InternaliseM a)
  deriving (Functor, Applicative, Monad, MonadState TypeState)

liftInternaliseM :: InternaliseM a -> InternaliseTypeM a
liftInternaliseM = InternaliseTypeM . lift

runInternaliseTypeM ::
  InternaliseTypeM a ->
  InternaliseM a
runInternaliseTypeM (InternaliseTypeM m) =
  evalStateT m 0

internaliseParamTypes ::
  [E.TypeBase (E.DimDecl VName) ()] ->
  InternaliseM [[I.TypeBase Shape Uniqueness]]
internaliseParamTypes ts =
  runInternaliseTypeM $ mapM (fmap (map onType) . internaliseTypeM) ts
  where
    onType = fromMaybe bad . hasStaticShape
    bad = error $ "internaliseParamTypes: " ++ pretty ts

internaliseLoopParamType ::
  E.TypeBase (E.DimDecl VName) () ->
  InternaliseM [I.TypeBase Shape Uniqueness]
internaliseLoopParamType et =
  concat <$> internaliseParamTypes [et]

internaliseReturnType ::
  E.TypeBase (E.DimDecl VName) () ->
  InternaliseM [I.TypeBase ExtShape Uniqueness]
internaliseReturnType et =
  runInternaliseTypeM (internaliseTypeM et)

internaliseLambdaReturnType ::
  E.TypeBase (E.DimDecl VName) () ->
  InternaliseM [I.TypeBase Shape NoUniqueness]
internaliseLambdaReturnType = fmap (map fromDecl) . internaliseLoopParamType

-- | As 'internaliseReturnType', but returns components of a top-level
-- tuple type piecemeal.
internaliseEntryReturnType ::
  E.TypeBase (E.DimDecl VName) () ->
  InternaliseM [[I.TypeBase ExtShape Uniqueness]]
internaliseEntryReturnType et =
  runInternaliseTypeM $
    mapM internaliseTypeM $
      case E.isTupleRecord et of
        Just ets | not $ null ets -> ets
        _ -> [et]

internaliseType ::
  E.TypeBase (E.DimDecl VName) () ->
  InternaliseM [I.TypeBase I.ExtShape Uniqueness]
internaliseType = runInternaliseTypeM . internaliseTypeM

newId :: InternaliseTypeM Int
newId = do
  i <- get
  put $ i + 1
  return i

internaliseDim ::
  E.DimDecl VName ->
  InternaliseTypeM ExtSize
internaliseDim d =
  case d of
    E.AnyDim -> Ext <$> newId
    E.ConstDim n -> return $ Free $ intConst I.Int64 $ toInteger n
    E.NamedDim name -> namedDim name
  where
    namedDim (E.QualName _ name) = do
      subst <- liftInternaliseM $ lookupSubst name
      case subst of
        Just [v] -> return $ I.Free v
        _ -> return $ I.Free $ I.Var name

internaliseTypeM ::
  E.StructType ->
  InternaliseTypeM [I.TypeBase ExtShape Uniqueness]
internaliseTypeM orig_t =
  case orig_t of
    E.Array _ u et shape -> do
      dims <- internaliseShape shape
      ets <- internaliseTypeM $ E.Scalar et
      return [I.arrayOf et' (Shape dims) $ internaliseUniqueness u | et' <- ets]
    E.Scalar (E.Prim bt) ->
      return [I.Prim $ internalisePrimType bt]
    E.Scalar (E.Record ets)
      -- XXX: we map empty records to bools, because otherwise
      -- arrays of unit will lose their sizes.
      | null ets -> return [I.Prim I.Bool]
      | otherwise ->
        concat <$> mapM (internaliseTypeM . snd) (E.sortFields ets)
    E.Scalar E.TypeVar {} ->
      error "internaliseTypeM: cannot handle type variable."
    E.Scalar E.Arrow {} ->
      error $ "internaliseTypeM: cannot handle function type: " ++ pretty orig_t
    E.Scalar (E.Sum cs) -> do
      (ts, _) <-
        internaliseConstructors
          <$> traverse (fmap concat . mapM internaliseTypeM) cs
      return $ I.Prim (I.IntType I.Int8) : ts
  where
    internaliseShape = mapM internaliseDim . E.shapeDims

internaliseConstructors ::
  M.Map Name [I.TypeBase ExtShape Uniqueness] ->
  ( [I.TypeBase ExtShape Uniqueness],
    M.Map Name (Int, [Int])
  )
internaliseConstructors cs =
  foldl' onConstructor mempty $ zip (E.sortConstrs cs) [0 ..]
  where
    onConstructor (ts, mapping) ((c, c_ts), i) =
      let (_, js, new_ts) =
            foldl' f (zip ts [0 ..], mempty, mempty) c_ts
       in (ts ++ new_ts, M.insert c (i, js) mapping)
      where
        f (ts', js, new_ts) t
          | Just (_, j) <- find ((== t) . fst) ts' =
            ( delete (t, j) ts',
              js ++ [j],
              new_ts
            )
          | otherwise =
            ( ts',
              js ++ [length ts + length new_ts],
              new_ts ++ [t]
            )

internaliseSumType ::
  M.Map Name [E.StructType] ->
  InternaliseM
    ( [I.TypeBase ExtShape Uniqueness],
      M.Map Name (Int, [Int])
    )
internaliseSumType cs =
  runInternaliseTypeM $
    internaliseConstructors
      <$> traverse (fmap concat . mapM internaliseTypeM) cs

-- | How many core language values are needed to represent one source
-- language value of the given type?
internalisedTypeSize :: E.TypeBase (E.DimDecl VName) () -> InternaliseM Int
internalisedTypeSize = fmap length . internaliseType

-- | Convert an external primitive to an internal primitive.
internalisePrimType :: E.PrimType -> I.PrimType
internalisePrimType (E.Signed t) = I.IntType t
internalisePrimType (E.Unsigned t) = I.IntType t
internalisePrimType (E.FloatType t) = I.FloatType t
internalisePrimType E.Bool = I.Bool

-- | Convert an external primitive value to an internal primitive value.
internalisePrimValue :: E.PrimValue -> I.PrimValue
internalisePrimValue (E.SignedValue v) = I.IntValue v
internalisePrimValue (E.UnsignedValue v) = I.IntValue v
internalisePrimValue (E.FloatValue v) = I.FloatValue v
internalisePrimValue (E.BoolValue b) = I.BoolValue b
