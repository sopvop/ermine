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
-- Module    :  Ermine.Syntax.Term
-- Copyright :  (c) Edward Kmett and Dan Doel 2012
-- License   :  BSD3
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable (DeriveDataTypeable)
--
-- This module provides the AST for Terms
--------------------------------------------------------------------
module Ermine.Syntax.Term
  (
  -- * Terms
    Term(..)
  , bindTerm
  -- * Hard Terms
  , HardTerm(..)
  , Terminal(..)
  -- * Bindings
  , DeclBound(..)
  , Binding(..)
  , BindingType(..)
  , Body(..)
  , Guarded(..)
  ) where

import Bound
import Bound.Var
import Control.Lens
import Control.Applicative
import Control.Monad (ap)
import Data.Bifoldable
import Data.Bitraversable
import Data.Foldable
import Data.IntMap hiding (map)
import Data.Map hiding (map)
import Data.String
import Ermine.Diagnostic
import Ermine.Syntax
import Ermine.Syntax.Global
import Ermine.Syntax.Kind hiding (Var)
import Ermine.Syntax.Pat
import Ermine.Syntax.Literal
import Ermine.Syntax.Scope
import Ermine.Syntax.Type hiding (App, Loc, Var, Tuple)
import Prelude.Extras
-- import Text.Trifecta.Diagnostic.Rendering.Prim

-- | Simple terms that can be compared with structural equality.
data HardTerm
  = Lit Literal
  | DataCon !Global
  | Tuple !Int      -- (,,)
  | Hole            -- ^ A placeholder that can take any type. Easy to 'Remember'.
  deriving (Eq, Show)

-- | This class provides a prism to match against or inject a 'HardTerm'.
class Terminal t where
  hardTerm :: Prism' t HardTerm

  litTerm :: Literal -> t
  litTerm = review hardTerm . Lit

  hole :: t
  hole = review hardTerm Hole

instance Terminal HardTerm where
  hardTerm = id

-- | Indicate if a definition is explicitly bound with a type annotation or implicitly bound without.
data BindingType t
  = Explicit t
  | Implicit
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Bound variables in a declaration are rather complicated. One can refer
-- to any of the following:
--   1. Definitions in the same declaration sequence
--   2. Variables bound in a pattern
--   3. Definitions in a where clause
-- the 'DeclBound' type captures these three cases in the respective constructors.
data DeclBound = D Int | P Int | W Int deriving (Eq,Ord,Show,Read)

-- | A body is the right hand side of a definition. This isn't a term because it has to perform simultaneous
-- matches on multiple patterns with backtracking.
-- Each Body contains a list of where clause bindings to which the body and
-- guards can refer.
data Body t a = Body [Pat t] (Guarded (Scope DeclBound (Term t) a)) [Binding t (Var Int a)]
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A datatype for representing potentially guarded cases of a function
-- body.
data Guarded tm = Unguarded tm
                | Guarded [(tm, tm)]
  deriving (Eq, Ord, Show, Read, Functor, Foldable, Traversable)

instance Bifunctor Body where
  bimap = bimapDefault

instance Bifoldable Body where
  bifoldMap = bifoldMapDefault

instance Bitraversable Body where
  bitraverse f g (Body ps ss wh) =
    Body <$> traverse (traverse f) ps
         <*> traverse (bitraverseScope f g) ss
         <*> traverse (bitraverse f (traverse g)) wh

-- | A Binding provides its source location as a rendering, knowledge of if it is explicit or implicitly bound
-- and a list of right hand side bindings.
data Binding t a = Binding !Rendering !(BindingType t) [Body t a]
  deriving (Show, Functor, Foldable, Traversable)

instance (Eq t, Eq a) => Eq (Binding t a) where
  Binding _ t bs == Binding _ t' bs' = t == t' && bs == bs'

instance Bifunctor Binding where
  bimap = bimapDefault

instance Bifoldable Binding where
  bifoldMap = bifoldMapDefault

instance Bitraversable Binding where
  bitraverse f g (Binding l bt bs) = Binding l <$> traverse f bt <*> traverse (bitraverse f g) bs

-- | Terms in the Ermine language.
data Term t a
  = Var a
  | App !(Term t a) !(Term t a)
  | HardTerm !HardTerm
  | Sig !(Term t a) t
  | Lam [Pat t] !(Scope Int (Term t) a)
  | Case !(Term t a) [Alt t (Term t) a]
  | Let [Binding t a] !(Scope Int (Term t) a)
  | Loc !Rendering !(Term t a) -- ^ informational link to where the term came from
  | Remember !Int !(Term t a) -- ^ Used to provide hole support.
  deriving (Show, Functor, Foldable, Traversable)

instance IsString a => IsString (Term t a) where
  fromString = Var . fromString

instance Variable (Term t) where
  var = prism Var $ \t -> case t of
    Var a -> Right a
    _     -> Left  t

instance App (Term t a) where
  app = prism (uncurry App) $ \t -> case t of
    App l r -> Right (l,r)
    _       -> Left t

instance (Choice p, Reviewable p, Applicative f) => Tup p f (Term t a) where
  tupled = prism hither yon
   where
   hither l = apps (HardTerm . Tuple $ length l) l
   yon original = go [] original
    where go stk (App f x) = go (x:stk) f
          go stk (HardTerm (Tuple n))
            | length stk == n = Right stk
          go _   _ = Left original

instance Terminal (Term t a) where
  hardTerm = prism HardTerm $ \t -> case t of
    HardTerm a -> Right a
    _          -> Left t

instance (Eq t, Eq a) => Eq (Term t a) where
  Loc _ l      == r            = l == r
  l            == Loc _ r      = l == r

  Remember _ l == r            = l == r -- ?
  l            == Remember _ r = l == r -- ?

  Var a        == Var b        = a == b
  Sig e t      == Sig e' t'    = e == e' && t == t'
  Lam p b      == Lam p' b'    = p == p' && b == b'
  HardTerm t   == HardTerm t'  = t == t'
  Case b as    == Case b' as'  = b == b' && as == as'
  App a b      == App c d      = a == c  && b == d
  _            == _            = False

instance Bifunctor Term where
  bimap = bimapDefault

instance Bifoldable Term where
  bifoldMap = bifoldMapDefault

instance Bitraversable Term where
  bitraverse f g = tm where
    tm (Var a)        = Var <$> g a
    tm (Sig e t)      = Sig <$> tm e <*> f t
    tm (Lam ps b)     = Lam <$> traverse (traverse f) ps <*> bitraverseScope f g b
    tm (HardTerm t)   = pure (HardTerm t)
    tm (App l r)      = App <$> tm l <*> tm r
    tm (Loc r b)      = Loc r <$> tm b
    tm (Remember i b) = Remember i <$> tm b
    tm (Case b as)    = Case <$> tm b <*> traverse (bitraverseAlt f g) as
    tm (Let bs ss)    = Let <$> traverse (bitraverse f g) bs <*> bitraverseScope f g ss
  {-# INLINE bitraverse #-}

instance Eq t => Eq1 (Term t)
instance Show t => Show1 (Term t)

instance Eq2 Term
instance Show2 Term

-- | Perform simultaneous substitution on terms and type annotations.
bindTerm :: (t -> t') -> (a -> Term t' b) -> Term t a -> Term t' b
bindTerm _ g (Var a)   = g a
bindTerm f g (App l r) = App (bindTerm f g l) (bindTerm f g r)
bindTerm f g (Sig e t) = Sig (bindTerm f g e) (f t)
bindTerm _ _ (HardTerm t) = HardTerm t
bindTerm f g (Lam ps (Scope b)) = Lam (fmap f <$> ps) (Scope (bimap f (fmap (bindTerm f g)) b))
bindTerm f g (Loc r b) = Loc r (bindTerm f g b)
bindTerm f g (Remember i b) = Remember i (bindTerm f g b)
bindTerm f g (Case b as) = Case (bindTerm f g b) (bindAlt f g <$> as)
bindTerm f g (Let bs (Scope b)) = Let (bindBinding f g <$> bs) (Scope (bimap f (fmap (bindTerm f g)) b))

bindBody :: (t -> t') -> (a -> Term t' b) -> Body t a -> Body t' b
bindBody f g (Body ps gs wh) =
  let s (Scope b) = Scope $ bimap f (fmap $ bindTerm f g) b in
    Body (fmap f <$> ps)
         (s <$> gs)
         (fmap (bindBinding f (unvar (pure . B) (fmap F . g))) wh)

bindBinding :: (t -> t') -> (a -> Term t' b) -> Binding t a -> Binding t' b
bindBinding f g (Binding r bt bs) = Binding r (fmap f bt) (bindBody f g <$> bs)

bindAlt :: (t -> t') -> (a -> Term t' b) -> Alt t (Term t) a -> Alt t' (Term t') b
bindAlt f g (Alt p (Scope b)) = Alt (fmap f p) (Scope (bindTerm f (Var . fmap (bindTerm f g)) b))

instance Applicative (Term t) where
  pure = Var
  (<*>) = ap

instance Monad (Term t) where
  return = Var
  m >>= g = bindTerm id g m

------------------------------------------------------------------------------
-- Variables
------------------------------------------------------------------------------

instance HasKindVars t t' k k' => HasKindVars (Term t a) (Term t' a) k k' where
  kindVars f = bitraverse (kindVars f) pure

instance HasTypeVars t t' tv tv' => HasTypeVars (Term t a) (Term t' a) tv tv' where
  typeVars f = bitraverse (typeVars f) pure

-- | Provides a traversal of term variables for variable->variable substitution or extracting free variables.
class HasTermVars s t a b | s -> a, t -> b, s b -> t, t a -> s where
  termVars :: Traversal s t a b

instance HasTermVars (Term t a) (Term t b) a b where
  termVars = traverse

instance HasTermVars s t a b => HasTermVars [s] [t] a b where
  termVars = traverse.termVars

instance HasTermVars s t a b => HasTermVars (IntMap s) (IntMap t) a b where
  termVars = traverse.termVars

instance HasTermVars s t a b => HasTermVars (Map k s) (Map k t) a b where
  termVars = traverse.termVars
