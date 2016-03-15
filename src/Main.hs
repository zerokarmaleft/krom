{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module Main where

import           Control.Concurrent
  (ThreadId, forkIO, forkFinally, threadDelay)
import           Control.Concurrent.Chan.Unagi
  (InChan, OutChan, dupChan, newChan, readChan, writeChan)
import           Control.Concurrent.MVar
  (MVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import           Control.Lens
  (Lens', ix, lens, makeClassy, only, over, preview, set, to, view, (^.), (^?), (.~))
import           Control.Lens.Prism
  (Prism', prism, _Just)
import           Control.Lens.Tuple
  (_1, _2, _3)
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
import           Data.Monoid
  ((<>))
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
  (Response, get, responseBody)
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
  { _kromNickName       = error "not configured" -- e.g. "krom"
  , _kromServerName     = error "not configured" -- e.g. "localhost"
  , _kromRemoteHost     = error "not configured" -- e.g. "localhost"
  , _kromRemotePort     = error "not configured" -- e.g. "6667"
  , _kromRemotePassword = error "not configured" -- e.g. "password"
  , _kromJoinChannels   = error "not configured" -- e.g. ["#krom"]
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
-- IRC lenses and prisms
-- ----------------------------------------------------------------------------

_MsgPrefix :: Lens' Message (Maybe Prefix)
_MsgPrefix =
  lens msg_prefix $ \msg p -> msg { msg_prefix=p }

_MsgCommand :: Lens' Message Command
_MsgCommand =
  lens msg_command $ \msg c -> msg { msg_command=c }

_MsgParams :: Lens' Message [Parameter]
_MsgParams =
  lens msg_params $ \msg ps -> msg { msg_params=ps }

_PrefixServer :: Prism' Prefix ByteString
_PrefixServer =
  prism Server $
        \p ->
          case p of
           Server serverName -> Right serverName
           _                 -> Left p

_PrefixNickName :: Prism' Prefix (ByteString, Maybe UserName, Maybe ServerName)
_PrefixNickName =
  prism (\(nickName, userName, serverName) -> NickName nickName userName serverName) $
        \p ->
          case p of
            NickName nickName userName serverName ->
              Right (nickName, userName, serverName)
            _ ->
              Left p

-- ----------------------------------------------------------------------------
-- IRC extensions
-- ----------------------------------------------------------------------------

password :: ByteString -> Message
password p = Message Nothing "PASS" [p]

bold :: ByteString -> ByteString
bold content = BS.singleton 0x02 <> content <> BS.singleton 0x0f

nickNamePrefix :: String -> String -> String -> Prefix
nickNamePrefix nickName userName serverName =
  NickName (CharBS.pack nickName) (Just $ CharBS.pack userName) (Just $ CharBS.pack serverName)

-- ----------------------------------------------------------------------------
-- IRC message predicates
-- ----------------------------------------------------------------------------

isPingMessage :: Message -> Bool
isPingMessage Message { msg_command="PING" } = True
isPingMessage _                              = False

isPrivateMessage :: Message -> Bool
isPrivateMessage Message { msg_command="PRIVMSG" } = True
isPrivateMessage _                                 = False

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

encodeMessages :: Monad m => Pipe Message ByteString m ()
encodeMessages = forever $
  do message <- await
     yield $ BS.append (encode message) "\r\n"

pongPingMessages :: Monad m => Pipe Message Message m ()
pongPingMessages = forever $
  do pingMessage <- await
     yield $ pingMessage { msg_command="PONG" }

echoMessages :: Monad m => Prefix -> Pipe Message Message m ()
echoMessages nickName = forever $
  do message <- await
     yield $ message { msg_prefix = Just nickName }

previewMessagesWithLinks :: MonadIO m => Prefix -> Pipe Message Message m ()
previewMessagesWithLinks nickName = loop
  where
    loop =
      do msg <- await
         let parsedURI = uriToString unEscapeString <$> (parseURI . CharBS.unpack =<< msg ^? _MsgParams . ix 1) <*> pure ""
         case parsedURI of
           Just uri ->
             do response <- liftIO . get $ uri
                yield $ previewMessage msg response
                loop
           Nothing ->
             loop

    getTitle :: Response LazyBS.ByteString -> Parameter
    getTitle response =
      let title = response ^. responseBody
                            . to (decodeUtf8With lenientDecode)
                            . html
                            . allNamed (only "title")
                            . contents
      in (LazyBS.toStrict . encodeUtf8 . Text.strip . Text.fromStrict) title

    previewMessage :: Message -> Response LazyBS.ByteString -> Message
    previewMessage msg response =
      let title          = getTitle response
          linker         = msg ^. _MsgPrefix . _Just . _PrefixNickName . _1
          channel        = msg ^. _MsgParams . ix 0
          previewMsgBody = title <> " linked by " <> linker
      in msg { msg_prefix = Just nickName
             , msg_params = [channel, previewMsgBody]
             }

-- ----------------------------------------------------------------------------
-- Thread management
-- ----------------------------------------------------------------------------

forkEffect :: Effect IO () -> SafeT IO ThreadId
forkEffect = liftIO . forkChild . runEffect

children :: MVar [MVar ()]
{-# NOINLINE children #-}
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

          let nickName = nickNamePrefix (config ^. kromNickName) (config ^. kromNickName) (config ^. kromServerName)

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
                     >-> echoMessages nickName
                     >-> encodeMessages
                     >-> toSocket clientSocket
          -- link previewer pipeline
          forkEffect $   subscribeMessages toLinkPreviewer
                     >-> previewMessagesWithLinks nickName
                     >-> encodeMessages
                     >-> toSocket clientSocket

          liftIO waitForChildren

main :: IO ()
main = runSafeT . flip runReaderT defaultKromConfig $ startPipes
