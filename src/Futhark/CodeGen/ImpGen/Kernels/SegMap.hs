{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

-- | Code generation for 'SegMap' is quite straightforward.  The only
-- trick is virtualisation in case the physical number of threads is
-- not sufficient to cover the logical thread space.  This is handled
-- by having actual workgroups run a loop to imitate multiple workgroups.
module Futhark.CodeGen.ImpGen.Kernels.SegMap (compileSegMap) where

import Control.Monad.Except
import qualified Futhark.CodeGen.ImpCode.Kernels as Imp
import Futhark.CodeGen.ImpGen
import Futhark.CodeGen.ImpGen.Kernels.Base
import Futhark.IR.KernelsMem
import Futhark.Util.IntegralExp (divUp)
import Prelude hiding (quot, rem)

-- | Compile 'SegMap' instance code.
compileSegMap ::
  Pattern KernelsMem ->
  SegLevel ->
  SegSpace ->
  KernelBody KernelsMem ->
  CallKernelGen ()
compileSegMap pat lvl space kbody = do
  let (is, dims) = unzip $ unSegSpace space
      dims' = map toInt64Exp dims
      num_groups' = toInt32Exp <$> segNumGroups lvl
      group_size' = toInt32Exp <$> segGroupSize lvl

  case lvl of
    SegThread {} -> do
      emit $ Imp.DebugPrint "\n# SegMap" Nothing
      let virt_num_groups =
            sExt32 $ product dims' `divUp` sExt64 (unCount group_size')
      sKernelThread "segmap" num_groups' group_size' (segFlat space) $
        virtualiseGroups (segVirt lvl) virt_num_groups $ \group_id -> do
          local_tid <- kernelLocalThreadId . kernelConstants <$> askEnv
          let global_tid =
                sExt64 group_id * sExt64 (unCount group_size')
                  + sExt64 local_tid

          zipWithM_ dPrimV_ is $
            map sExt64 $ unflattenIndex (map sExt64 dims') global_tid

          sWhen (isActive $ unSegSpace space) $
            compileStms mempty (kernelBodyStms kbody) $
              zipWithM_ (compileThreadResult space) (patternElements pat) $
                kernelBodyResult kbody
    SegGroup {} ->
      sKernelGroup "segmap_intragroup" num_groups' group_size' (segFlat space) $ do
        let virt_num_groups = sExt32 $ product dims'
        precomputeSegOpIDs (kernelBodyStms kbody) $
          virtualiseGroups (segVirt lvl) virt_num_groups $ \group_id -> do
            zipWithM_ dPrimV_ is $ unflattenIndex dims' $ sExt64 group_id

            compileStms mempty (kernelBodyStms kbody) $
              zipWithM_ (compileGroupResult space) (patternElements pat) $
                kernelBodyResult kbody
