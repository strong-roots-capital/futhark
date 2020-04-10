{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
-- | C code generator.  This module can convert a correct ImpCode
-- program to an equivalent C program.
module Futhark.CodeGen.Backends.MulticoreC
  ( compileProg
  , GC.CParts(..)
  , GC.asLibrary
  , GC.asExecutable
  ) where

import Control.Monad
import Data.FileEmbed

import qualified Language.C.Syntax as C
import qualified Language.C.Quote.OpenCL as C
import Futhark.Representation.ExplicitMemory (Prog, ExplicitMemory)
import Futhark.CodeGen.ImpCode.Multicore
import qualified Futhark.CodeGen.ImpGen.Multicore as ImpGen
import qualified Futhark.CodeGen.Backends.GenericC as GC
import Futhark.MonadFreshNames

compileProg :: MonadFreshNames m => Prog ExplicitMemory
            -> m GC.CParts
compileProg =
  GC.compileProg operations generateContext "" [DefaultSpace] [] <=<
  ImpGen.compileProg
  where generateContext = do

          let jobqueue_h  = $(embedStringFile "rts/c/jobqueue.h")
              scheduler_h = $(embedStringFile "rts/c/scheduler.h")

          mapM_ GC.earlyDecl [C.cunit|
                              $esc:jobqueue_h
                              $esc:scheduler_h
                             |]

          cfg <- GC.publicDef "context_config" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:s;|],
             [C.cedecl|struct $id:s { int debugging; };|])

          GC.publicDef_ "context_config_new" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:cfg* $id:s(void);|],
             [C.cedecl|struct $id:cfg* $id:s(void) {
                                 struct $id:cfg *cfg = (struct $id:cfg*) malloc(sizeof(struct $id:cfg));
                                 if (cfg == NULL) {
                                   return NULL;
                                 }
                                 cfg->debugging = 0;
                                 return cfg;
                               }|])

          GC.publicDef_ "context_config_free" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:cfg* cfg);|],
             [C.cedecl|void $id:s(struct $id:cfg* cfg) {
                                 free(cfg);
                               }|])

          GC.publicDef_ "context_config_set_debugging" GC.InitDecl $ \s ->
             ([C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
              [C.cedecl|void $id:s(struct $id:cfg* cfg, int detail) {
                          cfg->debugging = detail;
                        }|])

          GC.publicDef_ "context_config_set_logging" GC.InitDecl $ \s ->
             ([C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
              [C.cedecl|void $id:s(struct $id:cfg* cfg, int detail) {
                                 /* Does nothing for this backend. */
                                 (void)cfg; (void)detail;
                               }|])

          (fields, init_fields) <- GC.contextContents

          ctx <- GC.publicDef "context" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:s;|],
             [C.cedecl|struct $id:s {
                          struct scheduler scheduler;
                          int detail_memory;
                          int debugging;
                          int profiling;
                          typename lock_t lock;
                          char *error;
                          int total_runs;
                          long int total_runtime;
                          typename pthread_mutex_t profile_mutex;
                          $sdecls:fields
                        };|])

          GC.publicDef_ "context_new" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg);|],
             [C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg) {
                 struct $id:ctx* ctx = (struct $id:ctx*) malloc(sizeof(struct $id:ctx));
                 if (ctx == NULL) {
                   return NULL;
                 }

                 ctx->detail_memory = cfg->debugging;
                 ctx->debugging = cfg->debugging;
                 ctx->error = NULL;
                 create_lock(&ctx->lock);
                 $stms:init_fields

                 ctx->scheduler.ctx = ctx;
                 ctx->scheduler.num_threads = num_processors();
                 if (ctx->scheduler.num_threads < 1) return NULL;
                 if (job_queue_init(&ctx->scheduler.q, 64)) return NULL;
                 ctx->scheduler.threads = calloc(ctx->scheduler.num_threads, sizeof(pthread_t));

                 for (int i = 0; i < ctx->scheduler.num_threads; i++) {
                   if (pthread_create(&ctx->scheduler.threads[i], NULL, &futhark_worker, &ctx->scheduler) != 0) {
                     fprintf(stderr, "Failed to create thread (%d)\n", i);
                     return NULL;
                   }
                 }
                 CHECK_ERR(pthread_mutex_init(&ctx->profile_mutex, NULL), "pthred_mutex_init");
                 return ctx;
              }|])

          GC.publicDef_ "context_free" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|void $id:s(struct $id:ctx* ctx) {
                 job_queue_destroy(&ctx->scheduler.q);
                 for (int i = 0; i < ctx->scheduler.num_threads; i++) {
                   if (pthread_join(ctx->scheduler.threads[i], NULL) != 0) {
                     fprintf(stderr, "pthread_join failed on thread %d\n", i);
                   }
                 }
                 free_lock(&ctx->lock);
                 free(ctx);
               }|])

          GC.publicDef_ "context_sync" GC.InitDecl $ \s ->
            ([C.cedecl|int $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|int $id:s(struct $id:ctx* ctx) {
                                 (void)ctx;
                                 return 0;
                               }|])
          GC.publicDef_ "context_get_error" GC.InitDecl $ \s ->
            ([C.cedecl|char* $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|char* $id:s(struct $id:ctx* ctx) {
                                 char* error = ctx->error;
                                 ctx->error = NULL;
                                 return error;
                               }|])

          GC.publicDef_ "context_pause_profiling" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|void $id:s(struct $id:ctx* ctx) {
                         // ctx->profiling = 0;
                         (void)ctx;
                       }|])

          GC.publicDef_ "context_unpause_profiling" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|void $id:s(struct $id:ctx* ctx) {
                         ctx->profiling = 1;
                       }|])

          GC.publicDef_ "context_get_num_threads" GC.InitDecl $ \s ->
            ([C.cedecl|int $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|int $id:s(struct $id:ctx* ctx) {
                        return ctx->scheduler.num_threads;
                       }|])

operations :: GC.Operations Multicore ()
operations = GC.defaultOperations
             { GC.opsCompiler = compileOp
             , GC.opsCopy = copyMulticoreMemory
             }

copyMulticoreMemory :: GC.Copy Multicore ()
copyMulticoreMemory destmem destidx DefaultSpace srcmem srcidx DefaultSpace nbytes =
  GC.copyMemoryDefaultSpace destmem destidx srcmem srcidx nbytes
copyMulticoreMemory _ _ destspace _ _ srcspace _ =
  error $ "Cannot copy to " ++ show destspace ++ " from " ++ show srcspace


compileStructFields :: C.ToIdent a =>
                       [a] -> [C.Type] -> [C.FieldGroup]
compileStructFields  fargs fctypes =
  [ [C.csdecl|$ty:ty *$id:name;|]| (name, ty) <- zip fargs fctypes]


-- | Sets the field values of the struct
--   Assummes that vnames are fields of the struct
compileSetStructValues :: (C.ToIdent a1, C.ToIdent a2) =>
                           a1 -> [a2] -> [C.Stm]
compileSetStructValues struct vnames =
  [ [C.cstm|$id:struct.$id:name=&$id:name;|] | name <- vnames]


compileGetStructVals :: (C.ToIdent a1, C.ToIdent a2) =>
                         a2 -> [a1] -> [C.Type] -> [C.InitGroup]
compileGetStructVals struct fargs fctypes =
  [ [C.cdecl|$ty:ty $id:name = *$id:struct->$id:name;|]
            | (name, ty) <- zip fargs fctypes ]

paramToCType :: Param -> GC.CompilerM op s C.Type
paramToCType (ScalarParam _ pt) = pure $ GC.primTypeToCType pt
paramToCType (MemParam _ space') = GC.memToCType space'

functionRuntime :: String -> String
functionRuntime = (++"_total_runtime")

functionRuns :: String -> String
functionRuns = (++"_runs")


multiCoreReport :: [String] -> [C.BlockItem]
multiCoreReport names = report_kernels
  where longest_name = foldl max 0 $ map length names
        report_kernels = concatMap reportKernel names
        format_string name =
          let padding = replicate (longest_name - length name) ' '
          in unwords [name ++ padding,
                      "ran %5d times; avg: %8ldus; total: %8ldus\n"]
        reportKernel name =
          let runs = functionRuns name
              total_runtime = functionRuntime name
          in [[C.citem|
               fprintf(stderr,
                       $string:(format_string name),
                       ctx->$id:runs,
                       (long int) ctx->$id:total_runtime / (ctx->$id:runs != 0 ? ctx->$id:runs : 1),
                       (long int) ctx->$id:total_runtime);
              |],
              [C.citem|ctx->total_runtime += ctx->$id:total_runtime;|],
              [C.citem|ctx->total_runs += ctx->$id:runs;|]]

multicoreName :: String -> GC.CompilerM op s String
multicoreName s = do
  s' <- newVName ("futhark_mc_" ++ s)
  return $ baseString s' ++ "_" ++ show (baseTag s')

multicoreDef :: String -> (String -> C.Definition) -> GC.CompilerM op s String
multicoreDef s f = do
  s' <- multicoreName s
  GC.libDecl $ f s'
  return s'

compileOp :: GC.OpCompiler Multicore ()
compileOp (ParLoop ntasks i e (MulticoreFunc params prebody body tid)) = do
  fctypes <- mapM paramToCType params
  let fargs = map paramName params
  e' <- GC.compileExp e

  let ((prebody', body'), _) =
        GC.runCompilerM mempty operations blankNameSource () $
        (,)
        <$> GC.blockScope (GC.compileCode prebody)
        <*> GC.blockScope (GC.compileCode body)

  fstruct <- multicoreDef "parloop_struct" $ \s ->
     [C.cedecl|struct $id:s {
                 struct futhark_context *ctx;
                 $sdecls:(compileStructFields fargs fctypes)
               };|]

  ftask <- multicoreDef "parloop" $ \s ->
    [C.cedecl|int $id:s(void *args, int start, int end, int $id:tid) {
              struct $id:fstruct *$id:fstruct = (struct $id:fstruct*) args;
              struct futhark_context *ctx = $id:fstruct->ctx;
              typename int64_t st, et;
              if (ctx->profiling) {
                 st = get_wall_time();
              }
              $decls:(compileGetStructVals fstruct fargs fctypes)
              int $id:i = start;
              $items:prebody'
              for (; $id:i < end; $id:i++) {
                  $items:body'
              };
              if (ctx->profiling) {
                et = get_wall_time();
                typename uint64_t elapsed = et - st;

                CHECK_ERR(pthread_mutex_lock(&ctx->profile_mutex), "pthread_mutex_lock");
                ctx->$id:(functionRuns s)++;
                ctx->$id:(functionRuntime s) += elapsed;
                CHECK_ERR(pthread_mutex_unlock(&ctx->profile_mutex), "pthread_mutex_unlock");
              }
              return 0;
           }|]

  GC.contextField (functionRuntime ftask) [C.cty|typename int64_t|] $ Just [C.cexp|0|]
  GC.contextField (functionRuns ftask) [C.cty|int|] $ Just [C.cexp|0|]
  mapM_ GC.profileReport $ multiCoreReport  [ftask]


  GC.decl [C.cdecl|struct $id:fstruct $id:fstruct;|]
  GC.stm [C.cstm|$id:fstruct.ctx = ctx;|]
  GC.stms [C.cstms|$stms:(compileSetStructValues fstruct fargs)|]


  let ftask_name = ftask ++ "_task"
  GC.decl [C.cdecl|struct task $id:ftask_name;|]
  GC.stm  [C.cstm|$id:ftask_name.name = $string:ftask;|]
  GC.stm  [C.cstm|$id:ftask_name.fn = $id:ftask;|]
  GC.stm  [C.cstm|$id:ftask_name.args = &$id:fstruct;|]
  GC.stm  [C.cstm|$id:ftask_name.iterations = $exp:e';|]


  GC.stm [C.cstm|CHECK_ERR(scheduler_do_task(&ctx->scheduler, &$id:ftask_name, &$id:ntasks),
                 "scheduler failed to do task %s", $string:ftask);|]
compileOp (MulticoreCall [] f) =
  GC.stm [C.cstm|$id:f(ctx);|]

compileOp (MulticoreCall retvals f) =
  forM_ retvals $ \retval -> GC.stm [C.cstm|$id:retval = $id:f(ctx);|]
