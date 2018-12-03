{-# LANGUAGE FlexibleContexts #-}
module Main (main) where

import Control.Monad.IO.Class
import Data.Maybe
import System.FilePath
import System.Exit
import System.Environment
import qualified System.Info

import Futhark.Pipeline
import Futhark.Passes
import qualified Futhark.CodeGen.Backends.CVulkan as CVulkan
import Futhark.Util
import Futhark.Util.Pretty (prettyText)
import Futhark.Compiler.CLI

main :: IO ()
main = compilerMain () []
       "Compile Vulkan" "Generate Vulkan/C code from optimised Futhark program."
       gpuPipeline $ \() mode outpath prog -> do
         cprog <- either (`internalError` prettyText prog) return =<<
                  CVulkan.compileProg prog
         vk_sdk <- liftIO $ fromMaybe "." <$> lookupEnv "VULKAN_SDK"
         let cpath = outpath `addExtension` "c"
             hpath = outpath `addExtension` "h"
             extra_options
               | System.Info.os == "darwin" =
                   ["-framework", "OpenCL"]
               | System.Info.os == "mingw32" =
                   ["-I" ++ vk_sdk ++ "\\Include", "-L" ++ vk_sdk ++ "\\Lib", "-lvulkan-1"]
               | otherwise =
                   ["-lvulkan"]

         case mode of
           ToLibrary -> do
             let (header, impl) = CVulkan.asLibrary cprog
             liftIO $ writeFile hpath header
             liftIO $ writeFile cpath impl
           ToExecutable -> do
             liftIO $ writeFile cpath $ CVulkan.asExecutable cprog
             ret <- liftIO $ runProgramWithExitCode "gcc"
                    ([cpath, "-O3", "-std=c99", "-lm", "-o", outpath] ++ extra_options) ""
             case ret of
               Left err ->
                 externalErrorS $ "Failed to run gcc: " ++ show err
               Right (ExitFailure code, _, gccerr) ->
                 externalErrorS $ "gcc failed with code " ++
                 show code ++ ":\n" ++ gccerr
               Right (ExitSuccess, _, _) ->
                 return ()