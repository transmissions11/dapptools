{-# Language BangPatterns #-}
{-# Language DeriveGeneric #-}
{-# Language GeneralizedNewtypeDeriving #-}
{-# Language LambdaCase #-}
{-# Language OverloadedStrings #-}
{-# Language TemplateHaskell #-}

import qualified EVM as EVM

import EVM.Types
import EVM.Test

import Control.Lens

import Data.ByteString (ByteString)

import IPPrint.Colored (cpprint)
import Options.Generic
import System.Console.Readline

import qualified Data.ByteString.Lazy  as Lazy
import qualified Data.Map              as Map

data Command
  = Exec
      { code       :: ByteString
      , trace      :: Bool
      , calldata   :: Maybe ByteString
      , address    :: Maybe Address
      , caller     :: Maybe Address
      , origin     :: Maybe Address
      , coinbase   :: Maybe Address
      , value      :: Maybe Hexword
      , number     :: Maybe Hexword
      , timestamp  :: Maybe Hexword
      , gaslimit   :: Maybe Hexword
      , difficulty :: Maybe Hexword
      }
  | VMTest
      { file  :: String
      , test  :: [String]
      , debug :: Bool
      }
  deriving (Show, Generic, Eq)

instance ParseRecord Command

vmFromCommand :: Command -> EVM.VM
vmFromCommand opts =
  EVM.makeVm $ EVM.VMOpts
    { EVM.vmoptCode       = hexByteString "--code" (code opts)
    , EVM.vmoptCalldata   = maybe "" (hexByteString "--calldata")
                              (calldata opts)
    , EVM.vmoptValue      = word value 0
    , EVM.vmoptAddress    = addr address 1
    , EVM.vmoptCaller     = addr caller 2
    , EVM.vmoptOrigin     = addr origin 3
    , EVM.vmoptCoinbase   = addr coinbase 0
    , EVM.vmoptNumber     = word number 0
    , EVM.vmoptTimestamp  = word timestamp 0
    , EVM.vmoptGaslimit   = word gaslimit 0
    , EVM.vmoptDifficulty = word difficulty 0
    }
  where
    word f def = maybe def hexWord256 (f opts)
    addr f def = maybe def addressWord256 (f opts)

main :: IO ()
main = do
  opts <- getRecord "hsevm -- Ethereum evaluator"
  case opts of
    Exec {}  -> print (vmFromCommand opts)
    VMTest {} ->
      parseTestCases <$> Lazy.readFile (file opts) >>=
       \case
         Left err -> print err
         Right allTests ->
           let testFilter =
                 if null (test opts)
                 then id
                 else filter (\(x, _) -> elem x (test opts))
           in do
             let tests = testFilter (Map.toList allTests)
             putStrLn $ "Running " ++ show (length tests) ++ " tests"
             mapM_ (runVMTest (optsMode opts)) tests
             putStrLn ""


optsMode :: Command -> Mode
optsMode x = if debug x then Debug else Run

data Mode = Debug | Run

runVMTest :: Mode -> (String, VMTestCase) -> IO ()
runVMTest mode (_name, x) = do
  let vm = EVM.makeVm (testVmOpts x)
             & EVM.env . EVM.contracts .~ testContractsToVM (testContracts x)
  case mode of
    Run -> do vm' <- EVM.exec vm
              ok <- checkTestExpectation (testExpectation x) vm'
              if ok
                then putStr "."
                else putStr "F"

    Debug -> debugger vm

debugger :: EVM.VM -> IO ()
debugger vm = do
  cpprint (vm ^. EVM.state)
  cpprint (EVM.vmOp vm)
  cpprint (EVM.opParams vm)
  cpprint (vm ^. EVM.frames)
  if vm ^. EVM.done /= Nothing
    then do putStrLn "done"
    else
    readline "(evm) " >>=
      \case
        Nothing ->
          return ()
        Just line ->
          case words line of
            [] -> EVM.exec1 vm >>= debugger
            _  -> debugger vm
