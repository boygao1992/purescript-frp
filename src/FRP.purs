module FRP
  -- pure Combinator
  ( sample
  , sampleBy
  -- stateful Combinator
  , accum
  , foldl
  , step
  , switch
  -- Behavior
  , Behavior
  , pull
  -- Event
  , Event
  , filter
  , filterJust
  , mkEvent
  , shift
  , subscribe
  -- Now
  , Now
  , runNow
  -- Interop
  , SinkBehavior
  , sinkBehavior
  , refSinkBehavior
  , SinkEvent
  , sinkEvent
  ) where

import Prelude
import Control.Alternative (class Alt, class Plus)
import Control.Apply (lift2)
import Data.Maybe as Data.Maybe
import Data.Traversable as Data.Traversable
import Effect (Effect)
import Effect.Ref as Effect.Ref
import Foreign.Object as Foreign.Object

newtype Now a
  = Now (Effect a)

derive instance functorNow :: Functor Now

derive newtype instance applyNow :: Apply Now

derive newtype instance applicativeNow :: Applicative Now

derive newtype instance bindNow :: Bind Now

derive newtype instance monadNow :: Monad Now

runNow :: forall a. Now a -> Effect a
runNow (Now effect) = effect

newtype Behavior a
  = Behavior (Effect a)

pull :: forall a. Behavior a -> Now a
pull (Behavior effect) = Now effect

derive newtype instance functorBehavior :: Functor Behavior

derive newtype instance applyBehavior :: Apply Behavior

derive newtype instance applicativeBehavior :: Applicative Behavior

derive newtype instance bindBehavior :: Bind Behavior

derive newtype instance monadBehavior :: Monad Behavior

instance semigroupABehavior :: (Semigroup a) => Semigroup (Behavior a) where
  append = lift2 append

instance monoidABehavior :: (Monoid a) => Monoid (Behavior a) where
  mempty = pure mempty

newtype ABehavior event a
  = Sample (forall b. event (a -> b) -> event b)

filter :: forall a. (a -> Boolean) -> Event a -> Event a
filter predicate = filterJust <<< map toMaybe
  where
  toMaybe :: a -> Data.Maybe.Maybe a
  toMaybe a
    | predicate a = Data.Maybe.Just a
    | otherwise = Data.Maybe.Nothing

filterJust :: forall a. Event (Data.Maybe.Maybe a) -> Event a
filterJust eventMA = mkEvent subscribeA
  where
  subscribeA ::
    (a -> Effect Unit) ->
    Effect { unsubscribe :: Effect Unit }
  subscribeA continueA = subscribe eventMA (continueMA continueA)

  continueMA :: (a -> Effect Unit) -> Data.Maybe.Maybe a -> Effect Unit
  continueMA continueA = case _ of
    Data.Maybe.Nothing -> pure unit
    Data.Maybe.Just a -> continueA a

shift :: forall a. Event (Event a) -> Event a
shift eventE = mkEvent subscribeA
  where
  subscribeA ::
    (a -> Effect Unit) ->
    Effect { unsubscribe :: Effect Unit }
  subscribeA continueA = do
    unsubscribeRef :: Effect.Ref.Ref (Data.Maybe.Maybe (Effect Unit)) <-
      Effect.Ref.new Data.Maybe.Nothing
    subscribe eventE (continueE unsubscribeRef continueA)

  continueE ::
    Effect.Ref.Ref (Data.Maybe.Maybe (Effect Unit)) ->
    (a -> Effect Unit) ->
    Event a ->
    Effect Unit
  continueE unsubscribeRef continueA eventA = do
    popUnsubscribe unsubscribeRef
    subscription <- subscribe eventA continueA
    pushUnsubscribe subscription unsubscribeRef

  popUnsubscribe ::
    Effect.Ref.Ref (Data.Maybe.Maybe (Effect Unit)) ->
    Effect Unit
  popUnsubscribe = Data.Traversable.sequence_ <=< Effect.Ref.read

  pushUnsubscribe ::
    { unsubscribe :: Effect Unit } ->
    Effect.Ref.Ref (Data.Maybe.Maybe (Effect Unit)) ->
    Effect Unit
  pushUnsubscribe { unsubscribe } = Effect.Ref.write (Data.Maybe.Just unsubscribe)

sample :: forall a b. Behavior a -> Event (a -> b) -> Event b
sample = sampleBy (#)

sampleBy :: forall a b c. (a -> b -> c) -> Behavior a -> Event b -> Event c
sampleBy f (Behavior behaviorA) eventB = mkEvent subscribeC
  where
  subscribeC :: (c -> Effect Unit) -> Effect { unsubscribe :: Effect Unit }
  subscribeC continueC = subscribe eventB (applyF continueC)

  applyF :: (c -> Effect Unit) -> b -> Effect Unit
  applyF continueC b = do
    a <- behaviorA
    continueC (f a b)

accum :: forall a b. (b -> a -> b) -> b -> Event a -> Now (Behavior b)
accum f initB eventA =
  Now do
    sink <- refSinkBehavior initB
    _ <-
      subscribe eventA \a -> do
        b <- sink.read
        sink.write (f b a)
    pure sink.behavior

foldl :: forall a b. (b -> a -> b) -> b -> Event a -> Now (Event b)
foldl f initB eventA = do
  behaviorB <- accum f initB eventA
  pure $ sample behaviorB (const identity <$> eventA)

step :: forall a. a -> Event a -> Now (Behavior a)
step init = accum (const identity) init

switch :: forall a. Behavior a -> Event (Behavior a) -> Now (Behavior a)
switch init = map join <<< step init

newtype Event a
  = Subscribe ((a -> Effect Unit) -> Effect { unsubscribe :: Effect Unit })

instance functorEvent :: Functor Event where
  map :: forall a b. (a -> b) -> Event a -> Event b
  map f event =
    mkEvent \continueB ->
      let
        continueA = continueB <<< f
      in
        subscribe event continueA

instance altEvent :: Alt Event where
  alt :: forall a. Event a -> Event a -> Event a
  alt event1 event2 =
    mkEvent \continue -> do
      e1 <- subscribe event1 continue
      e2 <- subscribe event2 continue
      pure { unsubscribe: e1.unsubscribe *> e2.unsubscribe }

instance plusEvent :: Plus Event where
  empty :: forall a. Event a
  empty = mkEvent never
    where
    never _ = pure { unsubscribe: pure unit }

mkEvent ::
  forall a.
  ((a -> Effect Unit) -> Effect { unsubscribe :: Effect Unit }) ->
  Event a
mkEvent = Subscribe

subscribe ::
  forall a.
  Event a ->
  (a -> Effect Unit) ->
  Effect { unsubscribe :: Effect Unit }
subscribe (Subscribe e) = e

type SinkEvent a
  = { event :: Event a
    , push :: a -> Effect Unit
    }

sinkEvent :: forall a. Effect (SinkEvent a)
sinkEvent = do
  (subscribersRef :: Effect.Ref.Ref (Foreign.Object.Object (a -> Effect Unit))) <-
    Effect.Ref.new Foreign.Object.empty
  (newIdRef :: Effect.Ref.Ref Int) <-
    Effect.Ref.new 0
  let
    newId :: Effect String
    newId = map show $ Effect.Ref.modify (_ + 1) newIdRef

    subscribeA ::
      (a -> Effect Unit) ->
      Effect { unsubscribe :: Effect Unit }
    subscribeA continue = do
      id <- newId
      Effect.Ref.modify_ (Foreign.Object.insert id continue) subscribersRef
      pure
        { unsubscribe:
            Effect.Ref.modify_ (Foreign.Object.delete id) subscribersRef
        }

    push :: a -> Effect Unit
    push a = do
      subscribers <- Effect.Ref.read subscribersRef
      Data.Traversable.traverse_ (_ $ a) subscribers
  pure
    { event: mkEvent subscribeA
    , push
    }

type SinkBehavior a
  = { behavior :: Behavior a
    , read :: Effect a
    , write :: a -> Effect Unit
    }

sinkBehavior ::
  forall a.
  { read :: Effect a
  , write :: a -> Effect Unit
  } ->
  SinkBehavior a
sinkBehavior { read, write } =
  { behavior: Behavior read
  , read
  , write
  }

refSinkBehavior :: forall a. a -> Effect (SinkBehavior a)
refSinkBehavior init = do
  ref <- Effect.Ref.new init
  pure
    $ sinkBehavior
        { read: Effect.Ref.read ref
        , write: Effect.Ref.write <@> ref
        }
