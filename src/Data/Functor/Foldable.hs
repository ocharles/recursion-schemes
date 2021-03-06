{-# LANGUAGE CPP, TypeFamilies, Rank2Types, FlexibleContexts, FlexibleInstances, GADTs, StandaloneDeriving, UndecidableInstances #-}
#include "recursion-schemes-common.h"

#ifdef __GLASGOW_HASKELL__
{-# LANGUAGE DeriveDataTypeable #-}
#if __GLASGOW_HASKELL__ >= 800
{-# LANGUAGE ConstrainedClassMethods #-}
#endif
#if HAS_GENERIC
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables, DefaultSignatures, MultiParamTypeClasses, TypeOperators #-}
#endif
#endif

-----------------------------------------------------------------------------
-- |
-- Copyright   :  (C) 2008-2015 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  : "Samuel Gélineau" <gelisam@gmail.com>,
--               "Oleg Grenrus" <oleg.grenrus@iki.fi>,
--               "Ryan Scott" <ryan.gl.scott@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
----------------------------------------------------------------------------
module Data.Functor.Foldable
  (
  -- $intro

  -- * Base functors for fixed points
  -- $patternFunctors
    Base
  , ListF(..)
  -- * Fixed points
  -- $ fixedPoints
  , Fix(..), unfix
  , Mu(..), hoistMu
  , Nu(..), hoistNu
  -- * Folding
  , Recursive(..)
  -- ** Combinators
  , gapo
  , gcata
  , zygo
  , gzygo
  , histo
  , ghisto
  , futu
  , gfutu
  , chrono
  , gchrono
  -- ** Distributive laws
  , distCata
  , distPara
  , distParaT
  , distZygo
  , distZygoT
  , distHisto
  , distGHisto
  , distFutu
  , distGFutu
  -- * Unfolding
  , Corecursive(..)
  -- ** Combinators
  , gana
  -- ** Distributive laws
  , distAna
  , distApo
  , distGApo
  , distGApoT
  -- * Refolding
  , hylo
  , ghylo
  -- ** Changing representation
  , hoist
  , refix
  -- * Common names
  , fold, gfold
  , unfold, gunfold
  , refold, grefold
  -- * Mendler-style
  , mcata
  , mhisto
  -- * Elgot (co)algebras
  , elgot
  , coelgot
  -- * Zygohistomorphic prepromorphisms
  , zygoHistoPrepro
  -- * Effectful combinators
  , cataA
  , transverse
  , cotransverse
  ) where

import Control.Applicative
import Control.Comonad
import Control.Comonad.Trans.Class
import Control.Comonad.Trans.Env
import qualified Control.Comonad.Cofree as Cofree
import Control.Comonad.Cofree (Cofree(..))
import           Control.Comonad.Trans.Cofree (CofreeF, CofreeT(..))
import qualified Control.Comonad.Trans.Cofree as CCTC
import Control.Monad (liftM, join)
import Control.Monad.Free (Free(..))
import qualified Control.Monad.Free.Church as CMFC
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import           Control.Monad.Trans.Free (FreeF, FreeT(..))
import qualified Control.Monad.Trans.Free as CMTF
import Data.Functor.Identity
import Control.Arrow
import Data.Function (on)
import Data.Functor.Classes
import Data.Functor.Compose (Compose(..))
import Data.List.NonEmpty(NonEmpty((:|)), nonEmpty, toList)
import Text.Read
import Text.Show
#ifdef __GLASGOW_HASKELL__
import Data.Data hiding (gunfold)
#if HAS_POLY_TYPEABLE
#else
import qualified Data.Data as Data
#endif
#if HAS_GENERIC
import GHC.Generics (Generic (..), M1 (..), K1 (..), (:+:) (..), (:*:) (..))
#endif
#if HAS_GENERIC1
import GHC.Generics (Generic1)
#endif
#endif
import Numeric.Natural
import Data.Monoid (Monoid (..))
import Prelude

import qualified Data.Foldable as F
import qualified Data.Traversable as T

import qualified Data.Bifunctor as Bi
import qualified Data.Bifoldable as Bi
import qualified Data.Bitraversable as Bi

import           Data.Functor.Base hiding (head, tail)
import qualified Data.Functor.Base as NEF (NonEmptyF(..))

-- $setup
-- >>> import Control.Monad (void)
-- >>> import Data.Char (toUpper)

-- | This type family encodes the relationship between a type @t@ and it's
-- pattern functor. For example, for the list type
--
-- > data List a = Nil | Cons a (List a)
--
-- We have the corresponding pattern functor
--
-- > data ListF x a = Nil | Cons x a
--
-- In this case, @Base (List a) = ListF x@.
type family Base t :: * -> *

-- | The class of recursive data types.
--
-- A data type is recursive if it contains values of its own type in one or more
-- of it's constructors.
--
-- As an example, we have the list type
--
-- > data List a = Nil | Cons a (List a)
--
-- This is recursive because the @Cons@ constructor mentions the very type it's
-- defining (@List a@).
--
-- Note that the data type only needs to morally have this recursive
-- relationship. As an example of a slightly more interesting @Recursive@
-- instance, consider @Recursive Natural@. Here the pattern functor is @Maybe@,
-- where the choice between @Nothing@ and @Just@ represent the Peano axioms "0
-- is a natural number" and "For every natural number n, S(n) is a natural
-- number."
class Functor (Base t) => Recursive t where
  -- | @project@ converts a value of type @t@ into an isomorphic value built by
  -- @t@'s pattern functor. This witnesses a single recursive "step".
  --
  -- If we have
  --
  -- > data ListF x a = Nil | Cons x a
  -- > type instance Base [a] = ListF a
  --
  -- Then @project \@[a] :: [a] -> ListF a [a]@.
  --
  -- >>> project [1,2,3]
  -- Cons 1 [2,3]
  project :: t -> Base t t
#ifdef HAS_GENERIC
  default project :: (Generic t, Generic (Base t t), GCoerce (Rep t) (Rep (Base t t))) => t -> Base t t
  project = to . gcoerce . from
#endif

  -- | @cata@ is used to construct /catamorphisms/. A catamorphism on a type @T@
  -- is a function @T -> U@ that destructs an object of type @T@ according to its
  -- structure, calls itself recursively on any sub-components of type @T@, and
  -- combines this recursive result with the remaining components of @T@ to form
  -- @U@. Loosely speaking, catamorphisms are generalizations of the notion of
  -- a fold.
  --
  -- The prefix "cata" comes from the Greek 'κατα-' meaning
  -- "downward or according to". A useful mnemonic is to think of a catastrophe
  -- destroying something.
  --
  -- As an example, consider the catamorphism that takes the length of a list.
  --
  -- >>> :set -XLambdaCase
  -- >>> :{
  -- length :: [a] -> Int
  -- length = cata $ \case Nil -> 0
  --                       Cons _ n -> 1 + n
  -- :}
  --
  -- Consider the list @1 : 2 : []@. When we use @length@, for any list cons
  -- constructor, the tail of list is replaced with the length of that list. The
  -- given function uses this recursive call to implement a function for the
  -- length of the list - the length of an empty list is 0, and the length of an
  -- element prepended to a list is the length of that list plus 1.
  --
  -- >>> length [1,2]
  -- 2 
  cata :: (Base t a -> a) -- ^ a (Base t)-algebra
       -> t               -- ^ fixed point
       -> a               -- ^ result
  cata f = c where c = f . fmap c . project

  -- | @para@ is used to construct /paramorphisms/, which correspond to
  -- primitive recursive definitions. These recursive functions are similar to
  -- catamorphisms, but where we have the result of a recursive call, we also
  -- have the argument used to produce that result.
  --
  -- As an example of a paramorphism, Conor McBride provides this example on
  -- Stack Overflow (https://stackoverflow.com/questions/13317242/what-are-paramorphisms).
  --
  -- >>> :set -XLambdaCase
  -- >>> :{
  -- suffices :: [a] -> [[a]]
  -- suffices = para $ \case Nil -> []
  --                         Cons _ ( xs, suffxs ) -> xs : suffxs
  -- :}
  --
  -- >>> suffices "suffix"
  -- ["uffix","ffix","fix","ix","x",""]
  --
  -- To understand this result, consider breaking apart the string @"suffix"@
  -- into its pattern functor, with the recursive call and argument:
  --
  -- > "suffix" = Cons 's' ( "uffix", f "uffix" )
  --
  -- Thus our @suffices@ function is really just returning all of the arguments
  -- to the recursive call.
  para :: (Base t (t, a) -> a) -> t -> a
  para t = p where p x = t . fmap ((,) <*> p) $ project x

  -- | TODO
  gpara :: (Corecursive t, Comonad w) => (forall b. Base t (w b) -> w (Base t b)) -> (Base t (EnvT t w a) -> a) -> t -> a
  gpara t = gzygo embed t

  -- | @prepro@ is used to construct /prepromorphisms/ - these are like
  -- catamorphisms that have a preprocessing step. Jared Tobin provides a simple
  -- example where the preprocessing step is to take only "small" elements of
  -- a list.
  --
  -- >>> :set -XLambdaCase
  -- >>> :{
  -- filterLT :: (Num a, Ord a) => a -> ListF a x -> ListF a x
  -- filterLT _ Nil = Nil
  -- filterLT y (Cons x xs) | x < y     = Cons x xs
  --                        | otherwise = Nil
  -- :}
  --
  -- >>> :{
  -- prepro
  --   (filterLT 10)
  --   (\case Nil -> 0
  --          Cons x y -> x + y)
  --   [1, 2, 10, 3]
  -- :}
  -- 3
  --
  -- (@3 = 1 + 2@, when the @10@ was encountered our recursion was terminated.)
  prepro
    :: Corecursive t
    => (forall b. Base t b -> Base t b)
    -> (Base t a -> a)
    -> t
    -> a
  prepro e f = c where c = f . fmap (c . hoist e) . project

  --- | TODO A generalized prepromorphism
  gprepro
    :: (Corecursive t, Comonad w)
    => (forall b. Base t (w b) -> w (Base t b))
    -> (forall c. Base t c -> Base t c)
    -> (Base t (w a) -> a)
    -> t
    -> a
  gprepro k e f = extract . c where c = fmap f . k . fmap (duplicate . c . hoist e) . project

-- | TODO
distPara :: Corecursive t => Base t (t, a) -> (t, Base t a)
distPara = distZygo embed

-- | TODO
distParaT :: (Corecursive t, Comonad w) => (forall b. Base t (w b) -> w (Base t b)) -> Base t (EnvT t w a) -> EnvT t w (Base t a)
distParaT t = distZygoT embed t

-- | The class of co-recursive data types.
--
-- A data type is co-recursive if it can be built up productively from its
-- pattern functor.
--
-- As an example, we have the list type with its pattern functor:
--
-- > data List a = Nil | Cons a (List a)
-- > data ListF a x = Nil | Cons a x
--
-- Thus List is Corecursive because we can build a List from independent pattern
-- functors (as witnessed by 'embed').
class Functor (Base t) => Corecursive t where
  -- | Embed a pattern functor into the fixed-point type.
  --
  -- If we have
  --
  -- > data ListF x a = Nil | Cons x a
  -- > type instance Base [a] = ListF a
  --
  -- Then @embed \@[a] :: ListF a [a] -> [a]@.
  --
  -- >>> embed (Cons 1 [2, 3])
  -- [1,2,3]
  embed :: Base t t -> t
#ifdef HAS_GENERIC
  default embed :: (Generic t, Generic (Base t t), GCoerce (Rep (Base t t)) (Rep t)) => Base t t -> t
  embed = to . gcoerce . from
#endif

  -- | @ana@ is used to construct /anamorphisms/. An anamorphism on a type @T@
  -- is a function @U -> T@ that destructs @U@ in some way into a number of
  -- components. It recursively calls itself on components of type @U@, and
  -- combines this recursive result with other components to form @T@. Loosely
  -- speaking, anamorphisms are generalizations of the notion of an unfold.
  --
  -- The prefix "ana" comes from the Greek 'ana-' meaning "back" or "again".
  --
  -- As an example, consider the anamorphism that repeatedly applies a function
  -- to a value and returns a list of results:
  --
  -- >>> :{
  -- iterate :: (a -> a) -> a -> [a]
  -- iterate f = ana $ \x -> Cons x (f x)
  -- :}
  --
  -- Here we see that the anamorphism turns the seed value (initial point of
  -- iteration) into a list containing that value, and recursively calls itself
  -- with a new seed value - the result of one step of iteration.
  --
  -- >>> take 5 (iterate (*2) 1)
  -- [1,2,4,8,16]
  ana
    :: (a -> Base t a) -- ^ a (Base t)-coalgebra
    -> a               -- ^ seed
    -> t               -- ^ resulting fixed point
  ana g = a where a = embed . fmap a . g

  -- | TODO
  apo :: (a -> Base t (Either t a)) -> a -> t
  apo g = a where a = embed . (fmap (either id a)) . g

  -- | TODO Fokkinga's postpromorphism
  postpro
    :: Recursive t
    => (forall b. Base t b -> Base t b) -- natural transformation
    -> (a -> Base t a)                  -- a (Base t)-coalgebra
    -> a                                -- seed
    -> t
  postpro e g = a where a = embed . fmap (hoist e . a) . g

  -- | TODO A generalized postpromorphism
  gpostpro
    :: (Recursive t, Monad m)
    => (forall b. m (Base t b) -> Base t (m b)) -- distributive law
    -> (forall c. Base t c -> Base t c)         -- natural transformation
    -> (a -> Base t (m a))                      -- a (Base t)-m-coalgebra
    -> a                                        -- seed
    -> t
  gpostpro k e g = a . return where a = embed . fmap (hoist e . a . join) . k . liftM g

-- | A /hylomorphism/ is a combination of an anamorphism followed by a
-- catamorphism. However, category theory tells us that we can fuse these
-- recursive programs together, to avoid building the intermediate data
-- structure (deforestation).
--
-- An example of a hylomorphism is generating the nth term of the Fibonacci
-- sequence. First, we construct a tree in the shape of the Fibonacci series
-- (with leaves corresponding to @fib 0@ and @fib 1@), and then fold these tree
-- under summation:
--
-- >>> :set -XDeriveFunctor
-- >>> :{
-- data Tree a x = Leaf a | Branch x x deriving (Functor)
-- :}
--
-- >>> :set -XLambdaCase
-- >>> :{
-- fib :: Int -> Int
-- fib = hylo sumTree buildTree where
--   sumTree = \case Leaf n -> n
--                   Branch x y -> x + y
--   buildTree n | n == 0 = Leaf 0
--               | n == 1 = Leaf 1
--               | otherwise = Branch (n - 1) (n - 2)
-- :}
--
-- >>> fib 5
-- 5
hylo :: Functor f => (f b -> b) -> (a -> f a) -> a -> b
hylo f g = h where h = f . fmap h . g

-- | As catamorphisms are the general notion of a fold, this synonym is provided
-- if you want to use more familiar terminology.
--
-- > fold = cata
fold :: Recursive t => (Base t a -> a) -> t -> a
fold = cata

-- | As anamorphisms are the general notion of an unfold, this synonym is
-- provided if you want to use more familiar terminology.
--
-- > unfold = ana
unfold :: Corecursive t => (a -> Base t a) -> a -> t
unfold = ana

-- | "Refolding" may be a slightly more intuitive name for the concept of a
-- hylomorphism, so this synonym is provided for the cases where it may clarify
-- code.
--
-- > refold = hylo
refold :: Functor f => (f b -> b) -> (a -> f a) -> a -> b
refold = hylo

-- | Base functor of normal Haskell lists (@[]@).
data ListF a b = Nil | Cons a b
  deriving (Eq,Ord,Show,Read,Typeable
#if HAS_GENERIC
          , Generic
#endif
#if HAS_GENERIC1
          , Generic1
#endif
          )

#ifdef LIFTED_FUNCTOR_CLASSES
instance Eq2 ListF where
  liftEq2 _ _ Nil        Nil          = True
  liftEq2 f g (Cons a b) (Cons a' b') = f a a' && g b b'
  liftEq2 _ _ _          _            = False

instance Eq a => Eq1 (ListF a) where
  liftEq = liftEq2 (==)

instance Ord2 ListF where
  liftCompare2 _ _ Nil        Nil          = EQ
  liftCompare2 _ _ Nil        _            = LT
  liftCompare2 _ _ _          Nil          = GT
  liftCompare2 f g (Cons a b) (Cons a' b') = f a a' `mappend` g b b'

instance Ord a => Ord1 (ListF a) where
  liftCompare = liftCompare2 compare

instance Show a => Show1 (ListF a) where
  liftShowsPrec = liftShowsPrec2 showsPrec showList

instance Show2 ListF where
  liftShowsPrec2 _  _ _  _ _ Nil        = showString "Nil"
  liftShowsPrec2 sa _ sb _ d (Cons a b) = showParen (d > 10)
    $ showString "Cons "
    . sa 11 a
    . showString " "
    . sb 11 b

instance Read2 ListF where
  liftReadsPrec2 ra _ rb _ d = readParen (d > 10) $ \s -> nil s ++ cons s
    where
      nil s0 = do
        ("Nil", s1) <- lex s0
        return (Nil, s1)
      cons s0 = do
        ("Cons", s1) <- lex s0
        (a,      s2) <- ra 11 s1
        (b,      s3) <- rb 11 s2
        return (Cons a b, s3)

instance Read a => Read1 (ListF a) where
  liftReadsPrec = liftReadsPrec2 readsPrec readList

#else
instance Eq a   => Eq1   (ListF a) where eq1        = (==)
instance Ord a  => Ord1  (ListF a) where compare1   = compare
instance Show a => Show1 (ListF a) where showsPrec1 = showsPrec
instance Read a => Read1 (ListF a) where readsPrec1 = readsPrec
#endif

-- These instances cannot be auto-derived on with GHC <= 7.6
instance Functor (ListF a) where
  fmap _ Nil        = Nil
  fmap f (Cons a b) = Cons a (f b)

instance F.Foldable (ListF a) where
  foldMap _ Nil        = Data.Monoid.mempty
  foldMap f (Cons _ b) = f b

instance T.Traversable (ListF a) where
  traverse _ Nil        = pure Nil
  traverse f (Cons a b) = Cons a <$> f b

instance Bi.Bifunctor ListF where
  bimap _ _ Nil        = Nil
  bimap f g (Cons a b) = Cons (f a) (g b)

instance Bi.Bifoldable ListF where
  bifoldMap _ _ Nil        = mempty
  bifoldMap f g (Cons a b) = mappend (f a) (g b)

instance Bi.Bitraversable ListF where
  bitraverse _ _ Nil        = pure Nil
  bitraverse f g (Cons a b) = Cons <$> f a <*> g b

type instance Base [a] = ListF a
instance Recursive [a] where
  project (x:xs) = Cons x xs
  project [] = Nil

  para f (x:xs) = f (Cons x (xs, para f xs))
  para f [] = f Nil

instance Corecursive [a] where
  embed (Cons x xs) = x:xs
  embed Nil = []

  apo f a = case f a of
    Cons x (Left xs) -> x : xs
    Cons x (Right b) -> x : apo f b
    Nil -> []

type instance Base (NonEmpty a) = NonEmptyF a
instance Recursive (NonEmpty a) where
  project (x:|xs) = NonEmptyF x $ nonEmpty xs
instance Corecursive (NonEmpty a) where
  embed = (:|) <$> NEF.head <*> (maybe [] toList <$> NEF.tail)

type instance Base Natural = Maybe
instance Recursive Natural where
  project 0 = Nothing
  project n = Just (n - 1)
instance Corecursive Natural where
  embed = maybe 0 (+1)

-- | Cofree comonads are Recursive/Corecursive
type instance Base (Cofree f a) = CofreeF f a
instance Functor f => Recursive (Cofree f a) where
  project (x :< xs) = x CCTC.:< xs
instance Functor f => Corecursive (Cofree f a) where
  embed (x CCTC.:< xs) = x :< xs

-- | Cofree tranformations of comonads are Recursive/Corecusive
type instance Base (CofreeT f w a) = Compose w (CofreeF f a)
instance (Functor w, Functor f) => Recursive (CofreeT f w a) where
  project = Compose . runCofreeT
instance (Functor w, Functor f) => Corecursive (CofreeT f w a) where
  embed = CofreeT . getCompose

-- | Free monads are Recursive/Corecursive
type instance Base (Free f a) = FreeF f a

instance Functor f => Recursive (Free f a) where
  project (Pure a) = CMTF.Pure a
  project (Free f) = CMTF.Free f

improveF :: Functor f => CMFC.F f a -> Free f a
improveF x = CMFC.improve (CMFC.fromF x)
-- | It may be better to work with the instance for `CMFC.F` directly.
instance Functor f => Corecursive (Free f a) where
  embed (CMTF.Pure a) = Pure a
  embed (CMTF.Free f) = Free f
  ana               coalg = improveF . ana               coalg
  postpro       nat coalg = improveF . postpro       nat coalg
  gpostpro dist nat coalg = improveF . gpostpro dist nat coalg

-- | Free transformations of monads are Recursive/Corecursive
type instance Base (FreeT f m a) = Compose m (FreeF f a)
instance (Functor m, Functor f) => Recursive (FreeT f m a) where
  project = Compose . runFreeT
instance (Functor m, Functor f) => Corecursive (FreeT f m a) where
  embed = FreeT . getCompose

-- If you are looking for instances for the free MonadPlus, please use the
-- instance for FreeT f [].

-- If you are looking for instances for the free alternative and free
-- applicative, I'm sorry to disapoint you but you won't find them in this
-- package.  They can be considered recurive, but using non-uniform recursion;
-- this package only implements uniformly recursive folds / unfolds.

-- | Example boring stub for non-recursive data types
type instance Base (Maybe a) = Const (Maybe a)
instance Recursive (Maybe a) where project = Const
instance Corecursive (Maybe a) where embed = getConst

-- | Example boring stub for non-recursive data types
type instance Base (Either a b) = Const (Either a b)
instance Recursive (Either a b) where project = Const
instance Corecursive (Either a b) where embed = getConst

-- | TODO A generalized catamorphism
gfold, gcata
  :: (Recursive t, Comonad w)
  => (forall b. Base t (w b) -> w (Base t b)) -- ^ a distributive law
  -> (Base t (w a) -> a)                      -- ^ a (Base t)-w-algebra
  -> t                                        -- ^ fixed point
  -> a
gcata k g = g . extract . c where
  c = k . fmap (duplicate . fmap g . c) . project
gfold k g t = gcata k g t

-- | TODO
distCata :: Functor f => f (Identity a) -> Identity (f a)
distCata = Identity . fmap runIdentity

-- | TODO A generalized anamorphism
gunfold, gana
  :: (Corecursive t, Monad m)
  => (forall b. m (Base t b) -> Base t (m b)) -- ^ a distributive law
  -> (a -> Base t (m a))                      -- ^ a (Base t)-m-coalgebra
  -> a                                        -- ^ seed
  -> t
gana k f = a . return . f where
  a = embed . fmap (a . liftM f . join) . k
gunfold k f t = gana k f t

-- | TODO
distAna :: Functor f => Identity (f a) -> f (Identity a)
distAna = fmap Identity . runIdentity

-- | TODO A generalized hylomorphism
grefold, ghylo
  :: (Comonad w, Functor f, Monad m)
  => (forall c. f (w c) -> w (f c))
  -> (forall d. m (f d) -> f (m d))
  -> (f (w b) -> b)
  -> (a -> f (m a))
  -> a
  -> b
ghylo w m f g = extract . h . return where
  h = fmap f . w . fmap (duplicate . h . join) . m . liftM g
grefold w m f g a = ghylo w m f g a

-- | A /futumorphism/ is an 'ana'@morphism@ that builds /at least/ one further
-- recursive call per step.
--
-- For examples of futumorphisms, some suggested introductory material can be
-- found online:
--
-- * Patrick Thomson's blog post
--   <https://blog.sumtypeofway.com/recursion-schemes-part-iv-time-is-of-the-essence/ Recursion Schemes, Part IV: Time is of the Essence>
--   shows how futumorphisms can be used to grow plants.
-- * Jared Tobin's blog post
--   <https://jtobin.io/time-traveling-recursion Time Travelling Recursion Schemes>
--   shows a few simple examples of futumorphisms on lists.
futu :: Corecursive t => (a -> Base t (Free (Base t) a)) -> a -> t
futu = gana distFutu

-- | TODO
gfutu :: (Corecursive t, Functor m, Monad m) => (forall b. m (Base t b) -> Base t (m b)) -> (a -> Base t (FreeT (Base t) m a)) -> a -> t
gfutu g = gana (distGFutu g)

-- | TODO
distFutu :: Functor f => Free f (f a) -> f (Free f a)
distFutu (Pure fx) = Pure <$> fx
distFutu (Free ff) = Free . distFutu <$> ff

-- | TODO
distGFutu :: (Functor f, Functor h) => (forall b. h (f b) -> f (h b)) -> FreeT f h (f a) -> f (FreeT f h a)
distGFutu k = d where
  d = fmap FreeT . k . fmap d' . runFreeT
  d' (CMTF.Pure ff) = CMTF.Pure <$> ff
  d' (CMTF.Free ff) = CMTF.Free . d <$> ff

-------------------------------------------------------------------------------
-- Fix
-------------------------------------------------------------------------------

-- | TODO
newtype Fix f = Fix (f (Fix f))

-- | TODO
unfix :: Fix f -> f (Fix f)
unfix (Fix f) = f

instance Eq1 f => Eq (Fix f) where
  Fix a == Fix b = eq1 a b

instance Ord1 f => Ord (Fix f) where
  compare (Fix a) (Fix b) = compare1 a b

instance Show1 f => Show (Fix f) where
  showsPrec d (Fix a) =
    showParen (d >= 11)
      $ showString "Fix "
      . showsPrec1 11 a

instance Read1 f => Read (Fix f) where
  readPrec = parens $ prec 10 $ do
    Ident "Fix" <- lexP
    Fix <$> step (readS_to_Prec readsPrec1)

#ifdef __GLASGOW_HASKELL__
#if HAS_POLY_TYPEABLE
deriving instance Typeable Fix
deriving instance (Typeable f, Data (f (Fix f))) => Data (Fix f)
#else
instance Typeable1 f => Typeable (Fix f) where
   typeOf t = mkTyConApp fixTyCon [typeOf1 (undefined `asArgsTypeOf` t)]
     where asArgsTypeOf :: f a -> Fix f -> f a
           asArgsTypeOf = const

fixTyCon :: TyCon
#if MIN_VERSION_base(4,4,0)
fixTyCon = mkTyCon3 "recursion-schemes" "Data.Functor.Foldable" "Fix"
#else
fixTyCon = mkTyCon "Data.Functor.Foldable.Fix"
#endif
{-# NOINLINE fixTyCon #-}

instance (Typeable1 f, Data (f (Fix f))) => Data (Fix f) where
  gfoldl f z (Fix a) = z Fix `f` a
  toConstr _ = fixConstr
  gunfold k z c = case constrIndex c of
    1 -> k (z (Fix))
    _ -> error "gunfold"
  dataTypeOf _ = fixDataType

fixConstr :: Constr
fixConstr = mkConstr fixDataType "Fix" [] Prefix

fixDataType :: DataType
fixDataType = mkDataType "Data.Functor.Foldable.Fix" [fixConstr]
#endif
#endif

type instance Base (Fix f) = f
instance Functor f => Recursive (Fix f) where
  project (Fix a) = a
instance Functor f => Corecursive (Fix f) where
  embed = Fix

-- | TODO
hoist :: (Recursive s, Corecursive t)
      => (forall a. Base s a -> Base t a) -> s -> t
hoist n = cata (embed . n)

-- | TODO
refix :: (Recursive s, Corecursive t, Base s ~ Base t) => s -> t
refix = cata embed

-- | TODO
toFix :: Recursive t => t -> Fix (Base t)
toFix = refix

-- | TODO
fromFix :: Corecursive t => Fix (Base t) -> t
fromFix = refix


-------------------------------------------------------------------------------
-- Lambek
-------------------------------------------------------------------------------

-- | Lambek's lemma provides a default definition for 'project' in terms of 'cata' and 'embed'
lambek :: (Recursive t, Corecursive t) => (t -> Base t t)
lambek = cata (fmap embed)

-- | The dual of Lambek's lemma, provides a default definition for 'embed' in terms of 'ana' and 'project'
colambek :: (Recursive t, Corecursive t) => (Base t t -> t)
colambek = ana (fmap project)

-- | TODO
newtype Mu f = Mu (forall a. (f a -> a) -> a)
type instance Base (Mu f) = f
instance Functor f => Recursive (Mu f) where
  project = lambek
  cata f (Mu g) = g f
instance Functor f => Corecursive (Mu f) where
  embed m = Mu (\f -> f (fmap (fold f) m))

instance (Functor f, Eq1 f) => Eq (Mu f) where
  (==) = (==) `on` toFix

instance (Functor f, Ord1 f) => Ord (Mu f) where
  compare = compare `on` toFix

instance (Functor f, Show1 f) => Show (Mu f) where
  showsPrec d f = showParen (d > 10) $
    showString "fromFix " . showsPrec 11 (toFix f)

#ifdef __GLASGOW_HASKELL__
instance (Functor f, Read1 f) => Read (Mu f) where
  readPrec = parens $ prec 10 $ do
    Ident "fromFix" <- lexP
    fromFix <$> step readPrec
#endif

-- | A specialized, faster version of 'hoist' for 'Mu'.
hoistMu :: (forall a. f a -> g a) -> Mu f -> Mu g
hoistMu n (Mu mk) = Mu $ \roll -> mk (roll . n)


-- | Church encoded free monads are Recursive/Corecursive, in the same way that
-- 'Mu' is.
type instance Base (CMFC.F f a) = FreeF f a
cmfcCata :: (a -> r) -> (f r -> r) -> CMFC.F f a -> r
cmfcCata p f (CMFC.F run) = run p f
instance Functor f => Recursive (CMFC.F f a) where
  project = lambek
  cata f = cmfcCata (f . CMTF.Pure) (f . CMTF.Free)
instance Functor f => Corecursive (CMFC.F f a) where
  embed (CMTF.Pure a)  = CMFC.F $ \p _ -> p a
  embed (CMTF.Free fr) = CMFC.F $ \p f -> f $ fmap (cmfcCata p f) fr


-- | TODO
data Nu f where Nu :: (a -> f a) -> a -> Nu f
type instance Base (Nu f) = f
instance Functor f => Corecursive (Nu f) where
  embed = colambek
  ana = Nu
instance Functor f => Recursive (Nu f) where
  project (Nu f a) = Nu f <$> f a

instance (Functor f, Eq1 f) => Eq (Nu f) where
  (==) = (==) `on` toFix

instance (Functor f, Ord1 f) => Ord (Nu f) where
  compare = compare `on` toFix

instance (Functor f, Show1 f) => Show (Nu f) where
  showsPrec d f = showParen (d > 10) $
    showString "fromFix " . showsPrec 11 (toFix f)

#ifdef __GLASGOW_HASKELL__
instance (Functor f, Read1 f) => Read (Nu f) where
  readPrec = parens $ prec 10 $ do
    Ident "fromFix" <- lexP
    fromFix <$> step readPrec
#endif

-- | TOO A specialized, faster version of 'hoist' for 'Nu'.
hoistNu :: (forall a. f a -> g a) -> Nu f -> Nu g
hoistNu n (Nu next seed) = Nu (n . next) seed


-- | TODO
zygo :: Recursive t => (Base t b -> b) -> (Base t (b, a) -> a) -> t -> a
zygo f = gfold (distZygo f)

-- | TODO
distZygo
  :: Functor f
  => (f b -> b)             -- An f-algebra
  -> (f (b, a) -> (b, f a)) -- ^ A distributive for semi-mutual recursion
distZygo g m = (g (fmap fst m), fmap snd m)

-- | TODO
gzygo
  :: (Recursive t, Comonad w)
  => (Base t b -> b)
  -> (forall c. Base t (w c) -> w (Base t c))
  -> (Base t (EnvT b w a) -> a)
  -> t
  -> a
gzygo f w = gfold (distZygoT f w)

-- | TODO
distZygoT
  :: (Functor f, Comonad w)
  => (f b -> b)                        -- An f-w-algebra to use for semi-mutual recursion
  -> (forall c. f (w c) -> w (f c))    -- A base Distributive law
  -> f (EnvT b w a) -> EnvT b w (f a)  -- A new distributive law that adds semi-mutual recursion
distZygoT g k fe = EnvT (g (getEnv <$> fe)) (k (lower <$> fe))
  where getEnv (EnvT e _) = e

-- | TODO
gapo :: Corecursive t => (b -> Base t b) -> (a -> Base t (Either b a)) -> a -> t
gapo g = gunfold (distGApo g)

-- | TODO
distApo :: Recursive t => Either t (Base t a) -> Base t (Either t a)
distApo = distGApo project

-- | TODO
distGApo :: Functor f => (b -> f b) -> Either b (f a) -> f (Either b a)
distGApo f = either (fmap Left . f) (fmap Right)

-- | TODO
distGApoT
  :: (Functor f, Functor m)
  => (b -> f b)
  -> (forall c. m (f c) -> f (m c))
  -> ExceptT b m (f a)
  -> f (ExceptT b m a)
distGApoT g k = fmap ExceptT . k . fmap (distGApo g) . runExceptT

-- | /Histomorphisms/ are recursive functions that use "course-of-value"
-- iteration. Like a 'cata'@morphism@, a histomorphism folds some structure, but
-- unlike a catamorphism (which only has access to the immediate recursive call)
-- a histomorphism has access to all recursive calls.
--
-- An example of a histomorphism is to generate the nth term of the Fibonacci
-- sequence. Recall that generating a Fibonacci number requires the precedeeing
-- term, but also the term that preceeds that:
--
-- >>> :set -XLambdaCase
-- >>> :{
-- fib :: Natural -> Natural
-- fib = histo $ \case Nothing -> 0
--                     Just (_ :< Nothing) -> 1
--                     Just (n :< Just (m :< _)) -> n + m
-- :}
--
-- >>> fib 5
-- 5
histo :: Recursive t => (Base t (Cofree (Base t) a) -> a) -> t -> a
histo = gcata distHisto

-- | TODO
ghisto :: (Recursive t, Comonad w) => (forall b. Base t (w b) -> w (Base t b)) -> (Base t (CofreeT (Base t) w a) -> a) -> t -> a
ghisto g = gcata (distGHisto g)

-- | TODO
distHisto :: Functor f => f (Cofree f a) -> Cofree f (f a)
distHisto fc = fmap extract fc :< fmap (distHisto . Cofree.unwrap) fc

-- | TODO
distGHisto :: (Functor f, Functor h) => (forall b. f (h b) -> h (f b)) -> f (CofreeT f h a) -> CofreeT f h (f a)
distGHisto k = d where d = CofreeT . fmap (\fc -> fmap CCTC.headF fc CCTC.:< fmap (d . CCTC.tailF) fc) . k . fmap runCofreeT

-- | TODO
chrono :: Functor f => (f (Cofree f b) -> b) -> (a -> f (Free f a)) -> (a -> b)
chrono = ghylo distHisto distFutu

-- | TODO
gchrono :: (Functor f, Functor w, Functor m, Comonad w, Monad m) =>
           (forall c. f (w c) -> w (f c)) ->
           (forall c. m (f c) -> f (m c)) ->
           (f (CofreeT f w b) -> b) -> (a -> f (FreeT f m a)) ->
           (a -> b)
gchrono w m = ghylo (distGHisto w) (distGFutu m)

-- | TODO Mendler-style iteration
mcata :: (forall y. (y -> c) -> f y -> c) -> Fix f -> c
mcata psi = psi (mcata psi) . unfix

-- | TODO Mendler-style course-of-value iteration
mhisto :: (forall y. (y -> c) -> (y -> f y) -> f y -> c) -> Fix f -> c
mhisto psi = psi (mhisto psi) unfix . unfix

-- | TODO Elgot algebras
elgot :: Functor f => (f a -> a) -> (b -> Either a (f b)) -> b -> a
elgot phi psi = h where h = (id ||| phi . fmap h) . psi

-- | TODO Elgot coalgebras: <http://comonad.com/reader/2008/elgot-coalgebras/>
coelgot :: Functor f => ((a, f b) -> b) -> (a -> f a) -> a -> b
coelgot phi psi = h where h = phi . (id &&& fmap h . psi)

-- | TODO Zygohistomorphic prepromorphisms:
--
-- A corrected and modernized version of <http://www.haskell.org/haskellwiki/Zygohistomorphic_prepromorphisms>
zygoHistoPrepro
  :: (Corecursive t, Recursive t)
  => (Base t b -> b)
  -> (forall c. Base t c -> Base t c)
  -> (Base t (EnvT b (Cofree (Base t)) a) -> a)
  -> t
  -> a
zygoHistoPrepro f g t = gprepro (distZygoT f distHisto) g t

-------------------------------------------------------------------------------
-- Effectful combinators
-------------------------------------------------------------------------------

-- | Effectful 'fold'.
--
-- This is a type specialisation of 'cata'.
--
-- An example terminating a recursion immediately:
--
-- >>> cataA (\alg -> case alg of { Nil -> pure (); Cons a _ -> Const [a] })  "hello"
-- Const "h"
--
cataA :: (Recursive t) => (Base t (f a) -> f a) -> t -> f a
cataA = cata

-- | An effectful version of 'hoist'.
--
-- Properties:
--
-- @
-- 'transverse' 'sequenceA' = 'pure'
-- @
--
-- Examples:
--
-- The weird type of first argument allows user to decide
-- an order of sequencing:
--
-- >>> transverse (\x -> print (void x) *> sequence x) "foo" :: IO String
-- Cons 'f' ()
-- Cons 'o' ()
-- Cons 'o' ()
-- Nil
-- "foo"
--
-- >>> transverse (\x -> sequence x <* print (void x)) "foo" :: IO String
-- Nil
-- Cons 'o' ()
-- Cons 'o' ()
-- Cons 'f' ()
-- "foo"
--
transverse :: (Recursive s, Corecursive t, Functor f)
           => (forall a. Base s (f a) -> f (Base t a)) -> s -> f t
transverse n = cata (fmap embed . n)

-- | A coeffectful version of 'hoist'.
--
-- Properties:
--
-- @
-- 'cotransverse' 'distAna' = 'runIdentity'
-- @
--
-- Examples:
--
-- Stateful transformations:
--
-- >>> :{
-- cotransverse
--   (\(u, b) -> case b of
--     Nil -> Nil
--     Cons x a -> Cons (if u then toUpper x else x) (not u, a))
--   (True, "foobar") :: String
-- :}
-- "FoObAr"
--
-- We can implement `zipWith`
--
-- >>> :{
-- let zipWith' :: (a -> b -> c) -> [a] -> [b] -> [c]
--     zipWith' f = curry $ cotransverse $ \(xs, base) -> case (project xs, base) of
--       (Nil,      _)        -> Nil
--       (_,        Nil)      -> Nil
--       (Cons x a, Cons y b) -> Cons (f x y) (a, b)
-- :}
--
-- >>> zipWith' (*) [1,2,3] [4,5,6]
-- [4,10,18]
--
-- >>> zipWith' (*) [1,2,3] [4,5,6,8]
-- [4,10,18]
--
-- >>> zipWith' (*) [1,2,3,3] [4,5,6]
-- [4,10,18]
--
cotransverse :: (Recursive s, Corecursive t, Functor f)
             => (forall a. f (Base s a) -> Base t (f a)) -> f s -> t
cotransverse n = ana (n . fmap project)

-------------------------------------------------------------------------------
-- Not exposed anywhere
-------------------------------------------------------------------------------

-- | Read a list (using square brackets and commas), given a function
-- for reading elements.
_readListWith :: ReadS a -> ReadS [a]
_readListWith rp =
    readParen False (\r -> [pr | ("[",s) <- lex r, pr <- readl s])
  where
    readl s = [([],t) | ("]",t) <- lex s] ++
        [(x:xs,u) | (x,t) <- rp s, (xs,u) <- readl' t]
    readl' s = [([],t) | ("]",t) <- lex s] ++
        [(x:xs,v) | (",",t) <- lex s, (x,u) <- rp t, (xs,v) <- readl' u]

-------------------------------------------------------------------------------
-- GCoerce
-------------------------------------------------------------------------------

class GCoerce f g where
    gcoerce :: f a -> g a

instance GCoerce f g => GCoerce (M1 i c f) (M1 i c' g) where
    gcoerce (M1 x) = M1 (gcoerce x)

-- R changes to/from P with GHC-7.4.2 at least.
instance GCoerce (K1 i c) (K1 j c) where
    gcoerce = K1 . unK1

instance (GCoerce f g, GCoerce f' g') => GCoerce (f :*: f') (g :*: g') where
    gcoerce (x :*: y) = gcoerce x :*: gcoerce y

instance (GCoerce f g, GCoerce f' g') => GCoerce (f :+: f') (g :+: g') where
    gcoerce (L1 x) = L1 (gcoerce x)
    gcoerce (R1 x) = R1 (gcoerce x)

-- $intro
-- TODO

-- $patternFunctors
-- TODO

-- $fixedPoints
-- TODO
