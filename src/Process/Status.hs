-- | The status code runs a Status Process. This process keeps track
--   of a number of interval valies for a given torrent file and it
--   periodically updates the tracker process with the relevant
--   information about data uploaded, downloaded and how much is
--   left. The tracker is then responsible for using this data
--   correctly to tell the tracker what to do
{-# LANGUAGE FlexibleInstances #-}
module Process.Status (
    -- * Types
      StatusMsg(..)
    , PStat(..)
    -- * Channels
    , StatusChannel
    -- * State
    , StatusState(uploaded, downloaded, left)
    -- * Interface
    , start
    )
where

import Control.Concurrent
import Control.Concurrent.STM
import Control.DeepSeq
import Control.Exception (assert)

import Control.Monad.Reader
import Control.Monad.State

import Data.IORef
import qualified Data.Map as M

import Prelude hiding (log)

import Channels
import Process
import Process.Timer
import Supervisor
import Torrent
import Version

data StatusMsg = TrackerStat { trackInfoHash :: InfoHash
                             , trackIncomplete :: Maybe Integer
                             , trackComplete   :: Maybe Integer }
               | CompletedPiece InfoHash Integer
               | InsertTorrent InfoHash Integer TrackerChannel
               | RemoveTorrent InfoHash
               | TorrentCompleted InfoHash
               | RequestStatus InfoHash (TMVar StatusState)
               | RequestAllTorrents (TMVar [(InfoHash, StatusState)])
               | StatusTimerTick

data PStat = PStat { pInfoHash :: InfoHash
                   , pUploaded :: Integer
                   , pDownloaded :: Integer }

type StatusChannel = TChan StatusMsg

data CF  = CF { statusCh :: StatusChannel,
                statusTV :: TVar [PStat] }

instance Logging CF where
    logName _ = "Process.Status"

type ST = M.Map InfoHash StatusState

data StatusState = SState
             { uploaded :: Integer
             , downloaded :: Integer
             , left :: Integer
             , incomplete :: Maybe Integer
             , complete :: Maybe Integer
             , state :: TorrentState
             , trackerMsgCh :: TrackerChannel
             }

instance NFData StatusState where
    rnf (SState up down l inc comp st _) =
        rnf up `seq` rnf down `seq` rnf l `seq` rnf inc `seq` rnf comp `seq` rnf st `seq` ()

gatherStats :: (Integer, Integer) -> [(String, String)]
gatherStats (upload, download) =
    [("uploaded", show upload), ("downloaded", show download),
     ("version", version)]

instance Show StatusState where
    show (SState up down l inc comp st _) = concat
        ["{ Uploaded:   " ++ show up ++ "\n"
        ,"  Downloaded: " ++ show down ++ "\n"
        ,"  Left:       " ++ show l ++ "\n"
        ,"  State:      " ++ show st ++ "\n"
        ,"  Complete:   " ++ show comp ++ "\n"
        ,"  Incomplete: " ++ show inc ++ " }"]

-- | Start a new Status process with an initial torrent state and a
--   channel on which to transmit status updates to the tracker.
start :: Maybe FilePath -> StatusChannel -> TVar [PStat] -> SupervisorChannel -> IO ThreadId
start fp statusC tv supC = do
    r <- newIORef (0,0)
    _ <- registerSTM 5 statusC StatusTimerTick
    spawnP (CF statusC tv) M.empty
        ({-# SCC "Status" #-} cleanupP (pgm r) (defaultStopHandler supC) (cleanup r))
  where
    cleanup r = do
        st <- liftIO $ readIORef r
        case fp of
            Nothing -> return ()
            Just fpath -> liftIO $ writeFile fpath (show . gatherStats $ st)
    pgm r = do
        fetchUpdates r
        ch <- asks statusCh
        x <- liftIO . atomically $ readTChan ch
        recvMsg x
        pgm r

newMap :: Integer -> TrackerChannel -> StatusState
newMap l trackerMsgC =
    SState 0 0 l Nothing Nothing (if l == 0 then Seeding else Leeching) trackerMsgC

recvMsg :: StatusMsg -> Process CF ST ()
recvMsg msg = 
    case msg of
        TrackerStat ih ic c -> do
            modify (\s -> M.adjust (\st -> st { incomplete = ic, complete = c }) ih s)
        CompletedPiece ih bytes -> do
            modify (\s -> M.adjust (\st -> st { left = (left st) - bytes }) ih s)
        InsertTorrent ih l trackerMsgC ->
            modify (\s -> M.insert ih (newMap l trackerMsgC) s)
        RemoveTorrent ih -> modify (\s -> M.delete ih s)
        RequestStatus ih v -> do
            s <- get
            case M.lookup ih s of
                Nothing -> fail "Unknown InfoHash"
                Just st -> liftIO . atomically $ putTMVar v st
        RequestAllTorrents v -> do
            s <- get
            liftIO . atomically $ putTMVar v (M.toList s)
        TorrentCompleted ih -> do
            mp <- get
            let q = M.lookup ih mp
            ns  <- maybe (fail "Unknown Torrent") return q
            assert (left ns == 0) (return ())
            liftIO . atomically $ writeTChan (trackerMsgCh ns) Complete
            modify (\s -> M.insert ih (ns { state = Seeding}) s)
        StatusTimerTick -> do ch <- asks statusCh
                              registerSTM 5 ch StatusTimerTick >> return ()


fetchUpdates :: IORef (Integer, Integer) -> Process CF ST ()
fetchUpdates r = do
    tv <- asks statusTV
    updates <- liftIO . atomically $ do
                    updates <- readTVar tv
                    writeTVar tv []
                    return updates
    mapM_ (\(PStat ih up down) -> do
        (u, d) <- liftIO $ readIORef r
        let nup = u + up
            ndn = d + down
        liftIO $ nup `deepseq` ndn `deepseq` writeIORef r (nup, ndn)
        s <- get
        let adjusted = M.adjust (\st ->
                            st { uploaded = (uploaded st) + up
                               , downloaded = (downloaded st) + down }) ih s
        deepseq adjusted (put adjusted)) updates

