{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
--------------------------------------------------------------------
-- |
-- Module    :  Ermine.Kind
-- Copyright :  (c) Edward Kmett and Dan Doel 2012
-- License   :  BSD3
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable (DeriveDataTypeable)
--------------------------------------------------------------------
module Ermine.Type
  ( FieldName, HardT(..)
  , TK(..)
  , abstractKinds
  , instantiateKinds
  , hoistScope
  , bindK
  , bindT
  ) where

import Bound
import Control.Lens
import Control.Applicative
import Control.Monad (ap)
import Data.Bifunctor
import Data.Foldable
import Data.Set hiding (map)
import Data.Void
import Ermine.Global
import Ermine.Kind
import Prelude.Extras

type FieldName = String

data HardT
  = TupleT {-# UNPACK #-} !Int -- (,...,)   :: forall (k :: @). k -> ... -> k -> k -- n >= 2
  | ArrowT -- (->) :: * -> * -> *
  | ConT !Global (KindSchema Void)
  | ConcreteRho (Set FieldName)
  deriving (Eq, Ord, Show)

newtype TK k a = TK { runTK :: Type (Var Int (Kind k)) a }
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

liftTK :: Type k a -> TK k a
liftTK = TK . first (F . return)

bindTK :: (k -> Kind k') -> TK k a -> TK k' a
bindTK f = TK . bindK (return . fmap (>>= f)) . runTK

instance Monad (TK k) where
  return = TK . VarT
  TK t >>= f = TK (t >>= runTK . f)

instance Eq k => Eq1 (TK k) where (==#) = (==)
instance Ord k => Ord1 (TK k) where compare1 = compare
instance Show k => Show1 (TK k) where showsPrec1 = showsPrec

abstractKinds :: (k -> Maybe Int) -> Type k a -> TK k a
abstractKinds = error "TODO"

instantiateKinds :: (Int -> Kind a) -> TK k a -> Type k a
instantiateKinds = error "TODO"

hoistScope :: Functor f => (forall x. f x -> g x) -> Scope b f a -> Scope b g a
hoistScope t (Scope b) = Scope $ t (fmap t <$> b)

data Type k a
  = VarT a
  | AppT !(Type k a) !(Type k a)
  | HardT HardT
  | ForallT !Int [Scope Int Kind k] (Scope Int (TK k) a)
  | Exists [Kind k] [Scope Int (Type k) a]
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

instance Bifunctor Type where
  bimap f g = bindT (VarK . f) (VarT . g)

instance Eq k => Eq1 (Type k) where (==#) = (==)
instance Ord k => Ord1 (Type k) where compare1 = compare
instance Show k => Show1 (Type k) where showsPrec1 = showsPrec

instance Eq2 Type where (==##) = (==)
instance Ord2 Type where compare2 = compare
instance Show2 Type where showsPrec2 = showsPrec

bindK :: (k -> Kind k') -> Type k a -> Type k' a
bindK f = bindT f VarT

bindT :: (k -> Kind k') -> (a -> Type k' b) -> Type k a -> Type k' b
bindT _ g (VarT a)          = g a
bindT f g (AppT l r)        = AppT (bindT f g l) (bindT f g r)
bindT _ _ (HardT t)         = HardT t
bindT f g (ForallT n tks b) = ForallT n (map (>>>= f) tks) (hoistScope (bindTK f) b >>>= liftTK . g)
bindT f g (Exists ks cs)    = Exists (map (>>= f) ks) (map (\c -> hoistScope (bindK f) c >>>= g) cs)

instance Applicative (Type k) where
  pure = VarT
  (<*>) = ap

instance Monad (Type k) where
  return = VarT
  m >>= g = bindT VarK g m

