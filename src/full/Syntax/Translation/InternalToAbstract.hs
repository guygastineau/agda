{-# OPTIONS -cpp -fglasgow-exts -fallow-undecidable-instances #-}

{-|
    Translating from internal syntax to abstract syntax. Enables nice
    pretty printing of internal syntax.

    TODO

	- numbers on metas
	- fake dependent functions to independent functions
	- meta parameters
	- shadowing
-}
module Syntax.Translation.InternalToAbstract where

import Control.Monad.State
import Control.Monad.Error

import qualified Data.Map as Map
import Data.Map (Map)
import Data.List hiding (sort)
import Data.Traversable

import Syntax.Position
import Syntax.Common
import Syntax.Info as Info
import Syntax.Fixity
import Syntax.Abstract as A
import qualified Syntax.Concrete as C
import Syntax.Internal as I
import Syntax.Scope.Base
import Syntax.Scope.Monad

import TypeChecking.Monad as M
import TypeChecking.Reduce

import Utils.Monad
import Utils.Tuple

#include "../../undefined.h"

apps :: MonadTCM tcm => (Expr, [Arg Expr]) -> tcm Expr
apps (e, [])		    = return e
apps (e, arg@(Arg Hidden _) : args) =
    do	showImp <- showImplicitArguments
	if showImp then apps (App exprInfo e (unnamed <$> arg), args)
		   else apps (e, args)
apps (e, arg:args)	    =
    apps (App exprInfo e (unnamed <$> arg), args)

exprInfo :: ExprInfo
exprInfo = ExprRange noRange

reifyApp :: MonadTCM tcm => Expr -> [Arg Term] -> tcm Expr
reifyApp e vs = curry apps e =<< reify vs

class Reify i a | i -> a where
    reify :: MonadTCM tcm => i -> tcm a

instance Reify MetaId Expr where
    reify x@(MetaId n) =
	do  mi  <- getMetaInfo <$> lookupMeta x
	    let mi' = Info.MetaInfo (getRange mi)
				    (M.clScope mi)
				    (Just n)
	    iis <- map (snd /\ fst) . Map.assocs
		    <$> gets stInteractionPoints
	    case lookup x iis of
		Just ii@(InteractionId n)
			-> return $ A.QuestionMark $ mi' {metaNumber = Just n}
		Nothing	-> return $ A.Underscore mi'

instance Reify Term Expr where
    reify v =
	do  v <- instantiate v
	    case ignoreBlocking v of
		I.Var n vs   ->
		    do  x  <- liftTCM $ nameOfBV n `catchError` \_ -> freshName_ ("@" ++ show n)
			reifyApp (A.Var x) vs
		I.Def x vs   -> reifyApp (A.Def x) vs
		I.Con x vs   -> do
		  def <- theDef <$> getConstInfo x
		  case def of
		    Record _ _ xs _ _ _ -> do
		      vs <- reify $ map unArg vs
		      return $ A.Rec exprInfo $ zip xs vs
		    _	    -> reifyApp (A.Con x) vs
		I.Lam h b    ->
		    do	(x,e) <- reify b
			return $ A.Lam exprInfo (DomainFree h x) e
		I.Lit l	     -> return $ A.Lit l
		I.Pi a b     ->
		    do	Arg h a <- reify a
			(x,b)   <- reify b
			return $ A.Pi exprInfo [TypedBindings noRange h [TBind noRange [x] a]] b
		I.Fun a b    -> uncurry (A.Fun $ exprInfo)
				<$> reify (a,b)
		I.Sort s     -> reify s
		I.MetaV x vs -> apps =<< reify (x,vs)
		I.BlockedV _ -> __IMPOSSIBLE__

instance Reify Type Expr where
    reify (I.El _ t) = reify t

instance Reify Sort Expr where
    reify s =
	do  s <- normalise s
	    case s of
		I.Type n  -> return $ A.Set exprInfo n
		I.Prop	  -> return $ A.Prop exprInfo
		I.MetaS x -> reify x
		I.Suc s	  ->
		    do	suc <- freshName_ "suc"	-- TODO: hack
			e   <- reify s
			return $ A.App exprInfo (A.Var suc) (Arg NotHidden $ unnamed e)
		I.Lub s1 s2 ->
		    do	lub <- freshName_ "\\/"	-- TODO: hack
			(e1,e2) <- reify (s1,s2)
			let app x y = A.App exprInfo x (Arg NotHidden $ unnamed y)
			return $ A.Var lub `app` e1 `app` e2

instance Reify i a => Reify (Abs i) (Name, a) where
    reify (Abs s v) =
	do  x <- freshName_ s
	    e <- addCtx x (Arg NotHidden $ sort I.Prop) -- type doesn't matter
		 $ reify v
	    return (x,e)

instance Reify I.Telescope A.Telescope where
  reify EmptyTel = return []
  reify (ExtendTel arg tel) = do
    Arg h e <- reify arg
    (x,bs)  <- reify tel
    let r = getRange e
    return $ TypedBindings r h [TBind r [x] e] : bs

instance Reify i a => Reify (Arg i) (Arg a) where
    reify = traverse reify

instance Reify i a => Reify [i] [a] where
    reify = traverse reify

instance (Reify i1 a1, Reify i2 a2) => Reify (i1,i2) (a1,a2) where
    reify (x,y) = (,) <$> reify x <*> reify y

instance (Reify t t', Reify a a') 
         => Reify (Judgement t a) (Judgement t' a') where
    reify (HasType i t) = HasType <$> reify i <*> reify t
    reify (IsSort i) = IsSort <$> reify i


