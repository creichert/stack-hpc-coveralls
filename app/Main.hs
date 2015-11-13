{-# LANGUAGE QuasiQuotes #-}
module Main
    where

import Data.List (find)
import Data.Maybe (isJust)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as BSL
import Control.Monad (unless)
import Control.Applicative (pure, (<$>), (<*>))
import Control.Concurrent (threadDelay)
import System.Console.Docopt
import System.Environment (getArgs, getEnv, getEnvironment)
import System.Exit (exitFailure)

import SHC


urlApiV1 :: String
urlApiV1 = "https://coveralls.io/api/v1/jobs"

getServiceAndJobId :: IO (String, String)
getServiceAndJobId = do
    env <- getEnvironment
    case snd <$> find (isJust . flip lookup env . fst) ciEnvVars of
        Just (ciName, jobIdVarName) -> do
            jId <- getEnv jobIdVarName
            return (ciName, jId)
        _ -> error "Unsupported CI service."
    where ciEnvVars = [
           ("TRAVIS",      ("travis-ci", "TRAVIS_JOB_ID")),
           ("CIRCLECI",    ("circleci",  "CIRCLE_BUILD_NUM")),
           ("SEMAPHORE",   ("semaphore", "REVISION")),
           ("JENKINS_URL", ("jenkins",   "BUILD_ID")),
           ("CI_NAME",     ("codeship",  "CI_BUILD_NUMBER"))]

patterns :: Docopt
patterns = [docoptFile|USAGE.txt|]

getArgOrExit :: Arguments -> Option -> IO String
getArgOrExit = getArgOrExitWith patterns

defaultOr :: Arguments -> Option -> IO String -> IO String
defaultOr args opt action = maybe action return $ args `getArg` opt

getConfig :: Arguments -> IO Config
getConfig args = do
    pn <- args `getArgOrExit` argument "package-name"
    (sn, jId) <- getServiceAndJobId
    Config <$> args `getArgOrExit` argument "suite-name"
           <*> pure sn
           <*> pure jId
           <*> pure (args `getArg` longOption "repo-token")
           <*> getGitInfo
           <*> defaultOr args (longOption "hpc-dir") (getHpcDir pn)
           <*> defaultOr args (longOption "hpc-dir") getMixDir
           <*> pure (if args `isPresent` longOption "partial-coverage"
                        then PartialLines
                        else FullLines)

main :: IO ()
main = do
    args <- parseArgsOrExit patterns =<< getArgs
    stackGood <- checkStackVersion
    unless stackGood $ do
        putStrLn "Error: at least Stack 0.1.7 is required"
        exitFailure
    conf <- getConfig args
    coverallsJson <- generateCoverallsFromTix conf
    if args `isPresent` longOption "dont-send"
       then BSL.putStr $ encode coverallsJson
       else do
         response <- sendData conf urlApiV1 coverallsJson
         case response of
             PostSuccess url -> do
                 let apiUrl = url ++ ".json"
                 putStrLn $ "Job URL: " ++ apiUrl
                 -- wait 5 seconds until the page is available
                 threadDelay $ 5 * 1000 * 1000
                 coverageResult <- readCoverageResult apiUrl
                 case coverageResult of
                     Just totalCov -> putStrLn $ "Coverage: " ++ show totalCov
                     Nothing       -> putStrLn "Failed to read total coverage"
             PostFailure msg -> do
                 putStrLn $ "Error: " ++ msg
                 exitFailure