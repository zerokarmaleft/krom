{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}

module Main where

import           Control.Concurrent
  (ThreadId, forkIO, forkFinally, threadDelay)
import           Control.Concurrent.Chan.Unagi
  (InChan, OutChan, dupChan, newChan, readChan, writeChan)
import           Control.Concurrent.MVar
  (MVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import           Control.Lens
  ( ix, makeClassy, only, to, view, (^.), (^?))
import           Control.Monad
  (forever)
import           Control.Monad.Reader
  (MonadReader, ReaderT, ask, runReaderT)
import           Data.ByteString
  (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as CharBS
import qualified Data.ByteString.Lazy as LazyBS
import           Data.Char
  (chr)
import           Data.List.Lens
import           Data.Text.Encoding.Error
  (lenientDecode)
import           Data.Text.Lazy
  (Text)
import qualified Data.Text.Lazy as Text
import           Data.Text.Lazy.Encoding
  (decodeUtf8With, encodeUtf8)
import           Network.IRC
import           Network.URI
import           Network.Wreq
  (get, responseBody)
import           Pipes
import qualified Pipes.ByteString as PipesBS
import           Pipes.Network.TCP.Safe
  (Socket, closeSock, connect, fromSocket, toSocket)
import qualified Pipes.Prelude as Pipes
import           Pipes.Safe
  (SafeT, runSafeT)
import           System.IO.Unsafe
  (unsafePerformIO)
import           Text.Taggy.Lens
  (allNamed, contents, html)

-- ----------------------------------------------------------------------------
-- Global config
-- ----------------------------------------------------------------------------

data KromConfig = KromConfig
  { _kromNickName       :: String
  , _kromServerName     :: String
  , _kromRemoteHost     :: String
  , _kromRemotePort     :: String
  , _kromRemotePassword :: String
  , _kromJoinChannels   :: [String]
  } deriving (Show)

makeClassy ''KromConfig

defaultKromConfig :: KromConfig
defaultKromConfig = KromConfig
  { _kromNickName       = error "not configured"
  , _kromServerName     = error "not configured"
  , _kromRemoteHost     = error "not configured"
  , _kromRemotePort     = error "not configured"
  , _kromRemotePassword = error "not configured"
  , _kromJoinChannels   = error "not configured"
  }

registrationMessages :: KromConfig -> [Message]
registrationMessages config =
  let configuredPassword = CharBS.pack $ config ^. kromRemotePassword
      configuredNickName = CharBS.pack $ config ^. kromNickName
      joinChanMessages   = map (joinChan . CharBS.pack) $ config ^. kromJoinChannels
  in [ password configuredPassword
     , nick     configuredNickName
     , user     configuredNickName "0" "*" configuredNickName
     ] ++ joinChanMessages

-- ----------------------------------------------------------------------------
-- IRC extensions
-- ----------------------------------------------------------------------------

password :: ByteString -> Message
password p = Message Nothing "PASS" [p]

bold :: ByteString -> ByteString
bold content = BS.concat [BS.singleton 0x02, content, BS.singleton 0x0f]

-- ----------------------------------------------------------------------------
-- IRC message predicates
-- ----------------------------------------------------------------------------

isPingMessage :: Message -> Bool
isPingMessage Message { msg_command="PING" } = True
isPingMessage _                              = False

isPrivateMessage :: Message -> Bool
isPrivateMessage Message { msg_command="PRIVMSG" } = True
isPrivateMessage _                                 = False

hasMessageBodyWithLink :: Message -> Bool
hasMessageBodyWithLink Message { msg_params=(_:msgBody:_) } = isURI . CharBS.unpack $ msgBody
hasMessageBodyWithLink _ = False

nickNamePrefix :: String -> String -> String -> Prefix
nickNamePrefix nickName userName serverName =
  NickName (CharBS.pack nickName) (Just $ CharBS.pack userName) (Just $ CharBS.pack serverName)

-- ----------------------------------------------------------------------------
-- IRC message pipes
-- ----------------------------------------------------------------------------

receiveMessages :: MonadIO m => Socket -> Producer ByteString m ()
receiveMessages clientSocket =
  PipesBS.concats . view PipesBS.lines $ fromSocket clientSocket 1024

broadcastMessages :: MonadIO m => InChan Message -> Consumer Message m ()
broadcastMessages messages = forever $
  do message <- await
     liftIO $ writeChan messages message

subscribeMessages :: MonadIO m => OutChan Message -> Producer Message m ()
subscribeMessages messages = forever $
  do message <- liftIO $ readChan messages
     yield message

parseMessages :: Monad m => Pipe ByteString Message m ()
parseMessages = loop
  where
    loop =
      do buffer <- await
         case decode buffer of
           (Just message) -> yield message >> loop
           Nothing        -> loop

formatMessages :: Monad m => Pipe Message ByteString m ()
formatMessages = forever $
  do message <- await
     yield $ CharBS.pack (show message ++ "\n")

pongPingMessages :: Monad m => Pipe Message Message m ()
pongPingMessages = forever $
  do pingMessage <- await
     yield $ pingMessage { msg_command="PONG" }

encodeMessages :: Monad m => Pipe Message ByteString m ()
encodeMessages = forever $
  do message <- await
     yield $ BS.append (encode message) "\r\n"

echoMessages :: Monad m => Prefix -> Pipe Message Message m ()
echoMessages nickName = forever $
  do message <- await
     yield $ message { msg_prefix = Just nickName }

getLinkPreview :: MonadIO m => Parameter -> m Parameter
getLinkPreview param =
  do let mURI = parseURI . CharBS.unpack $ param
     case mURI of
       Just uri ->
         do response <- liftIO . get $ (uriToString unEscapeString uri) ""
            let title = response ^. responseBody
                                  . to (decodeUtf8With lenientDecode)
                                  . html
                                  . allNamed (only "title")
                                  . contents
            return . LazyBS.toStrict . encodeUtf8 . Text.strip . Text.fromStrict $ title
       Nothing ->
         return "Invalid URI"

previewMessagesWithLinks :: MonadIO m => Prefix -> Pipe Message Message m ()
previewMessagesWithLinks nickName = loop
  where
    loop =
      do message <- await
         case msg_params message ^? ix 1 of
           Just messageBody ->
             do title <- lift . getLinkPreview $ messageBody
                let linker = msg_prefix message
                    formattedTitle =
                      case msg_prefix message of
                        Just (NickName linker _ _) -> BS.concat [bold title, " linked by ", linker]
                        Nothing                    -> bold title
                yield $ message { msg_prefix = Just nickName
                                , msg_params = ["#beatdown", formattedTitle]
                                }
                loop
           Nothing ->
             loop

-- ----------------------------------------------------------------------------
-- Thread management
-- ----------------------------------------------------------------------------

forkEffect = liftIO . forkChild . runEffect

children :: MVar [MVar ()]
children = unsafePerformIO (newMVar [])

waitForChildren :: IO ()
waitForChildren =
  do cs <- takeMVar children
     case cs of
       []   -> return ()
       m:ms -> do
          putMVar children ms
          takeMVar m
          waitForChildren

forkChild :: IO () -> IO ThreadId
forkChild io =
  do mvar <- newEmptyMVar
     cs <- takeMVar children
     putMVar children (mvar:cs)
     forkFinally io (\_ -> putMVar mvar ())

-- ----------------------------------------------------------------------------
-- Application entry point
-- ----------------------------------------------------------------------------

startPipes :: ReaderT KromConfig (SafeT IO) ()
startPipes =
  do config <- ask
     connect (config ^. kromRemoteHost) (config ^. kromRemotePort) $ \(clientSocket, remoteAddr) -> lift $
       do (fromIRCServer, toLogger) <- liftIO newChan
          toPonger                  <- liftIO $ dupChan fromIRCServer
          toEchoer                  <- liftIO $ dupChan fromIRCServer
          toLinkPreviewer           <- liftIO $ dupChan fromIRCServer

          -- establish session
          runEffect $   each (registrationMessages config)
                    >-> encodeMessages
                    >-> toSocket clientSocket

          -- broadcaster pipeline
          forkEffect $   receiveMessages clientSocket
                     >-> parseMessages
                     >-> broadcastMessages fromIRCServer
          -- logger pipeline
          forkEffect $   subscribeMessages toLogger
                     >-> formatMessages
                     >-> PipesBS.stdout
          -- ponger pipeline
          forkEffect $   subscribeMessages toPonger
                     >-> Pipes.filter isPingMessage
                     >-> pongPingMessages
                     >-> encodeMessages
                     >-> toSocket clientSocket
          -- echoer pipeline
          forkEffect $   subscribeMessages toEchoer
                     >-> Pipes.filter isPrivateMessage
                     >-> echoMessages (nickNamePrefix (config ^. kromNickName) (config ^. kromNickName) (config ^. kromServerName))
                     >-> encodeMessages
                     >-> toSocket clientSocket
          -- link previewer pipeline
          forkEffect $   subscribeMessages toLinkPreviewer
                     >-> Pipes.filter hasMessageBodyWithLink
                     >-> previewMessagesWithLinks (nickNamePrefix (config ^. kromNickName) (config ^. kromNickName) (config ^. kromServerName))
                     >-> encodeMessages
                     >-> toSocket clientSocket

          liftIO waitForChildren

main :: IO ()
main = runSafeT . (flip runReaderT) defaultKromConfig $ startPipes
