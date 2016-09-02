{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main where
import Control.Lens                         -- from: lens
import Control.Monad.Except                 -- from: mtl
import Control.Monad.Trans (MonadIO(..))    -- from: mtl
import Data.Aeson.Lens                      -- from: lens-aeson
import Data.ByteString.Lazy (ByteString)    -- from: bytestring
import Data.Foldable
import Data.List (sortBy)
import Data.Text.Lazy (fromStrict)          -- from: text
import Data.Text.Lazy.Encoding (encodeUtf8) -- from: text
import Network.AMQP                         -- from: amqp
import Network.Wreq (responseBody,
                     responseStatus,
                     statusCode)            -- from: wreq
import qualified Network.Wreq as Wreq       -- from: wreq

import RateLimit
import SeenEvents
import Skippable
import Types

-- https://developer.github.com/v3/#rate-limiting
-- TODO: Auth
-- TODO: Rate-Limiting awareness
-- TODO: (minimum) sleep
-- TODO: User-agent
-- TODO: etag


main :: IO ()
main = putStrLn "Hello, Haskell!"

--run :: MonadIO m => (Event -> m ()) -> m ()
--run f = void . runSeenEventsT . runEvents $ getData >>= runReaderT respHandlers
--  where respHandlers = (ReaderT $ flip getRepos eventHandlers) >> ReaderT inspectRateLimit
--        eventHandlers = \_ -> return () --trackEvents
--        runEvents = flip foreverRateLimitT 1000000 . logErrors

--run :: MonadIO m => (Event -> m ()) -> m ()
--run f = void . flip runStateT mempty . logErrors $ getData -- >>= respHandlers --flip getRepos (lift . eventHandlers)
--  where liftTracking :: Monad m => (r -> m a) -> r -> StateT LastSeenEvent m a
--        liftTracking f r = lift $ f r
--        respHandlers = flip getRepos (eventHandlers)
--        eventHandlers = trackEvents >>@ f

logErrors :: (Show r, MonadIO m) => ExceptT r m a -> m ()
logErrors m = runExceptT m >>= either (liftIO . print) (void . return)

getData :: (MonadError PollError m, MonadIO m) => m (Wreq.Response ByteString)
getData = do r <- liftIO $ Wreq.get "https://api.github.com/events?per_page=200"
             case r ^. responseStatus . statusCode of
               200 -> return r
               x   -> throwError $ StatusError x

getRepos :: (AsValue body, Applicative m) => Wreq.Response body -> (Event -> m ()) -> m ()
getRepos r k = traverse_ k . sortBy sortf $ r ^.. responseBody . values . test
  where sortf = curry $ uncurry compare . (view $ eventId `alongside` eventId)

printEvents :: MonadIO m => Event -> m ()
printEvents = liftIO . print

repo' :: AsValue s => ReifiedFold s Repo
repo' = Repo <$> Fold (key "repo" . key "name" . _String)

blah :: AsValue s => ReifiedFold s EventType
blah = Fold $ key "type" . _String . et

test :: AsValue s => Fold s Event
test = runFold $ Event <$> (Fold $ key "id" . _Integer) <*> blah <*> repo'

bindAMQPChan :: IO (Connection, Channel)
bindAMQPChan = do conn <- openConnection "127.0.0.1" "/" "guest" "guest"
                  chan <- openChannel conn
                  declareExchange chan newExchange { exchangeName = "github-events",
                                                     exchangeType = "topic" }
                  return (conn, chan)

publishEvent :: Channel -> Event -> IO ()
publishEvent chan evt = void $ publishMsg chan "github-events" (evt ^. eventType . re et)
  newMsg { msgBody = encodeUtf8 (fromStrict $ evt ^. repo . coerced) }
