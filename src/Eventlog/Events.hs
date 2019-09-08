{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}
module Eventlog.Events(chunk) where

import GHC.RTS.Events hiding (Header, header)
import Prelude hiding (init, lookup)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Map (Map)

import Eventlog.Types
import Eventlog.Total
import Data.List
import Data.Function
import Data.Word
import Data.Time
import Data.Time.Clock.POSIX
import qualified Data.Map as Map
import Data.Vector.Unboxed (Vector, (!?))
import Data.Maybe
import Data.Version
import Text.ParserCombinators.ReadP
import Control.Monad
import Data.Char

type PartialHeader = Int -> Header

fromNano :: Word64 -> Double
fromNano e = fromIntegral e * 1e-9

chunk :: FilePath -> IO (Header,Map Text (Double, Double), [Frame], [Trace])
chunk f = do
  (EventLog _ e) <- either error id <$> readEventLogFromFile f
  (ph, frames, traces) <- eventsToHP e
  let (counts, totals) = total frames
  return $ (ph counts, totals, frames, traces)

checkGHCVersion :: EL -> Maybe String
checkGHCVersion EL { ident = Just (version,_)}  | version <= makeVersion [8,4,4]  =
                                                  Just $ "Warning: The eventlog has been generated with GHC version "
                                                  ++ show version
                                                  ++ ", which does not support profiling events in the eventlog."
checkGHCVersion EL { pargs = Just args, ident = Just (version,_)}| version > makeVersion [8,4,4] &&
                                                                   version <= makeVersion [8,9,0] &&
                                                                   ("-hr" `elem` args ||
                                                                    "-hb" `elem` args) =
                                                                   Just $ "Warning: The eventlog has been generated with GHC version"
                                                                   ++ show version
                                                                   ++ ", which does not support biographical or retainer profiling."
checkGHCVersion _ = Nothing


eventsToHP :: Data -> IO (PartialHeader, [Frame], [Trace])
eventsToHP (Data es) = do
  let
      el@EL{..} = foldEvents es
      fir = Frame (fromNano start) []
      las = Frame (fromNano end) []
  maybe (return ()) putStrLn (checkGHCVersion el)
  return $ (elHeader el, fir : reverse (las: normalise frames) , traces)

normalise :: [(Word64, [Sample])] -> [Frame]
normalise fs = map (\(t, ss) -> Frame (fromNano t) ss) fs


data EL = EL
  { pargs :: !(Maybe [String])
  , ident :: Maybe (Version, String)
  , ccMap :: !(Map.Map Word32 CostCentre)
  , clocktimeSec :: !Word64
  , samples :: !(Maybe (Word64, [Sample]))
  , frames :: ![(Word64, [Sample])]
  , traces :: ![Trace]
  , start :: !Word64
  , end :: !Word64 } deriving Show

data CostCentre = CC { cid :: Word32
                     , label :: Text
                     , modul :: Text
                     , loc :: Text } deriving Show

initEL :: Word64 -> EL
initEL t = EL
  { pargs = Nothing
  , ident = Nothing
  , clocktimeSec = 0
  , samples = Nothing
  , frames = []
  , traces = []
  , start = t
  , end = 0
  , ccMap = Map.empty
  }

foldEvents :: [Event] -> EL
foldEvents (e:es) =
  let res = foldl' folder  (initEL (evTime e)) (e:es)
  in addFrame 0 res
foldEvents [] = error "Empty event log"

folder :: EL -> Event -> EL
folder el (Event t e _) = el &
  updateLast t .
    case e of
      -- Traces
      RtsIdentifier _ ident -> addIdent ident
      Message s -> addTrace (Trace (fromNano t) (T.pack s))
      UserMessage s -> addTrace (Trace (fromNano t) (T.pack s))
      HeapProfBegin {} -> addFrame t
      HeapProfCostCentre cid l m loc _  -> addCostCentre cid (CC cid l m loc)
      HeapProfSampleBegin {} -> addFrame t
      HeapProfSampleCostCentre _hid r d s -> addCCSample r d s
      HeapProfSampleString _hid res k -> addSample (Sample k (fromIntegral res))
      ProgramArgs _ as -> addArgs as
      WallClockTime _ s _ -> addClocktime s
      _ -> id

addIdent :: String -> EL -> EL
addIdent s el = el { ident = parseIdent s }

parseIdent :: String -> Maybe (Version, String)
parseIdent s = listToMaybe $ flip readP_to_S s $ do
  void $ string "GHC-"
  [v1, v2, v3] <- replicateM 3 (intP <* optional (char '.'))
  skipSpaces
  return (makeVersion [v1,v2,v3])
  where
    intP = do
      x <- munch1 isDigit
      return $ read x


addCostCentre :: Word32 -> CostCentre -> EL -> EL
addCostCentre s cc el = el { ccMap = Map.insert s cc (ccMap el) }

addCCSample :: Word64 -> Word8 -> Vector Word32 -> EL -> EL
addCCSample res _sd st el =
  fromMaybe (addSample (Sample "NONE" (fromIntegral res)) el) $ do
  cid <- st !? 0
  CC{label, modul} <- Map.lookup cid (ccMap el)
  let fmtl = modul <> "." <> label
  return $ addSample (Sample fmtl (fromIntegral res)) el


addClocktime :: Word64 -> EL -> EL
addClocktime s el = el { clocktimeSec = s }

addArgs :: [String] -> EL -> EL
addArgs as el = el { pargs = Just as }

addTrace :: Trace -> EL -> EL
addTrace t el = el { traces = t : traces el }

addFrame :: Word64 -> EL -> EL
addFrame t el =
  el { samples = Just (t, [])
     , frames = sampleToFrames (samples el) (frames el) }

sampleToFrames :: Maybe (Word64, [Sample]) -> [(Word64, [Sample])]
                                           -> [(Word64, [Sample])]
sampleToFrames (Just (t, ss)) fs = (t, (reverse ss)) : fs
sampleToFrames Nothing fs = fs

addSample :: Sample -> EL -> EL
addSample s el = el { samples = go <$> (samples el) }
  where
    go (t, ss) = (t, (s:ss))

updateLast :: Word64 -> EL -> EL
updateLast t el = el { end = t }

formatDate :: Word64 -> T.Text
formatDate sec =
  let posixTime :: POSIXTime
      posixTime = realToFrac sec
  in
    T.pack $ formatTime defaultTimeLocale "%Y-%m-%d, %H:%M %Z" (posixSecondsToUTCTime posixTime)

elHeader :: EL -> PartialHeader
elHeader EL{..} =
  let title = maybe "" (T.unwords . map T.pack) pargs
      date = formatDate clocktimeSec
  in Header title date "" ""


