{-# LANGUAGE OverloadedStrings #-}

module Web.SocketIO.Connection
    (   runConnection
    ,   newSessionTable
    )  where

--------------------------------------------------------------------------------
import              Web.SocketIO.Types
import              Web.SocketIO.Util
import              Web.SocketIO.Session

--------------------------------------------------------------------------------
import qualified    Data.HashMap.Strict                     as H
import              Data.IORef.Lifted
import              Control.Applicative                     ((<$>))
import              Control.Concurrent.Lifted               (fork)
import              Control.Concurrent.Chan.Lifted 
import              Control.Concurrent.MVar.Lifted
import              Control.Monad.Reader       
import              Control.Monad.Writer       
import              System.Random                           (randomRIO)
import              System.Timeout.Lifted

--------------------------------------------------------------------------------
newSessionTable :: IO (IORef Table)
newSessionTable = newIORef H.empty

--------------------------------------------------------------------------------
updateSession :: (Table -> Table) -> ConnectionM ()
updateSession update = do
    table <- getSessionTable
    liftIO (modifyIORef table update)

--------------------------------------------------------------------------------
lookupSession :: SessionID -> ConnectionM (Maybe Session)
lookupSession sessionID = do
    tableVar <- getSessionTable
    table <- liftIO (readIORef tableVar)
    return (H.lookup sessionID table)

--------------------------------------------------------------------------------
executeHandler :: HandlerM () -> BufferHub -> ConnectionM [Listener]
executeHandler handler bufferHub = liftIO $ execWriterT (runReaderT (runHandlerM handler) bufferHub)

--------------------------------------------------------------------------------
runConnection :: Env -> Request -> IO Text
runConnection env req = do
    runReaderT (runConnectionM (handleConnection req)) env

--------------------------------------------------------------------------------
handleConnection :: Request -> ConnectionM Text
handleConnection Handshake = do
    globalBuffer <- envGlobalBuffer <$> getEnv
    globalBufferClone <- dupChan globalBuffer
    localBuffer <- newChan
    let bufferHub = BufferHub localBuffer globalBufferClone
    handler <- getHandler
    sessionID <- genSessionID
    listeners <- executeHandler handler bufferHub
    timeout' <- newEmptyMVar

    let session = Session sessionID Connecting bufferHub listeners timeout'

    _ <- fork $ setTimeout sessionID timeout'

    updateSession (H.insert sessionID session)

    runSession SessionSyn session
    where   genSessionID = liftIO $ fmap (fromString . show) (randomRIO (10000000000000000000, 99999999999999999999 :: Integer)) :: ConnectionM Text

handleConnection (Connect sessionID) = do

    result <- lookupSession sessionID
    clearTimeout sessionID
    case result of
        Just (Session sessionID' status buffer listeners timeout') -> do
            let session = Session sessionID' Connected buffer listeners timeout'
            case status of
                Connecting -> do
                    updateSession (H.insert sessionID' session)
                    runSession SessionAck session
                Connected ->
                    runSession SessionPolling session
                s -> do
                    debug . Error $ fromText sessionID' ++ "    Undefined status: " ++ (fromString $ show s)
                    runSession SessionError NoSession

        Just NoSession -> do
            debug . Error $ fromText sessionID ++ "    No session" 
            runSession SessionError NoSession
        Nothing -> do
            debug . Error $ fromText sessionID ++ "    Unable to find session" 
            runSession SessionError NoSession

handleConnection (Disconnect sessionID) = do

    result <- lookupSession sessionID
    response <- case result of
        Just session -> runSession SessionDisconnect session
        Nothing -> return ""

    clearTimeout sessionID
    updateSession (H.delete sessionID)

    return response

handleConnection (Emit sessionID emitter) = do
    clearTimeout sessionID

    result <- lookupSession sessionID
    case result of
        Just session -> runSession (SessionEmit emitter) session
        Nothing      -> runSession SessionError NoSession

--------------------------------------------------------------------------------
setTimeout :: SessionID -> MVar () -> ConnectionM ()
setTimeout sessionID timeout' = do
    configuration <- getConfiguration
    let duration = (closeTimeout configuration) * 1000000
    debug . Debug $ fromText sessionID ++ "    Set Timeout"
    result <- timeout duration $ takeMVar timeout'

    case result of
        Just _  -> setTimeout sessionID timeout'
        Nothing -> do
            debug . Debug $ fromText sessionID ++ "    Close Session"
            updateSession (H.delete sessionID)

--------------------------------------------------------------------------------
clearTimeout :: SessionID -> ConnectionM ()
clearTimeout sessionID = do
    result <- lookupSession sessionID
    case result of
        Just (Session _ _ _ _ timeout') -> do
            debug . Debug $ fromText sessionID ++ "    Clear Timeout"
            putMVar timeout' ()
        Just _                          -> return ()
        Nothing                         -> return ()