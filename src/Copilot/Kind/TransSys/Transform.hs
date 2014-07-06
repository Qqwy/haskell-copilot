--------------------------------------------------------------------------------

module Copilot.Kind.TransSys.Transform
  ( traverseExpr
  , mergeNodes
  , linearize
  , removeCycles
  , complete ) where

import Copilot.Kind.TransSys.Spec
import Copilot.Kind.Misc.Type
import Copilot.Kind.Misc.Operators

import Copilot.Kind.Misc.Utils

import qualified Data.Map   as Map
import qualified Data.Graph as Graph

--------------------------------------------------------------------------------

traverseExpr :: (forall a . Expr a -> Expr a) -> Expr t -> Expr t
traverseExpr f (Ite t c e1 e2) = f (Ite t (f c) (f e1) (f e2))
traverseExpr f (Op1 t op e) = f (Op1 t op (f e))
traverseExpr f (Op2 t op e1 e2) = f (Op2 t op (f e1) (f e2))
traverseExpr f e = f e

--------------------------------------------------------------------------------

prefix :: String -> LVar -> LVar
prefix s1 (LVar s2) = LVar $ s1 ++ "." ++ s2

renameLVars :: (LVar -> LVar) -> Node -> Node
renameLVars updateVar node =
  node { nodeVars = nodeVars' }
  where

    nodeVars' = Map.fromList $
                [ (updateVar v, updateDescr descr)
                | (v, descr) <- Map.toList (nodeVars node) ]

    updateDescr (LVarDescr t def) = LVarDescr t $ case def of
      Pre val var -> Pre val (updateVar var)
      Ext gvar    -> Ext gvar
      Expr e      -> Expr $ traverseExpr updateExpr e

    updateExpr :: forall t . Expr t -> Expr t
    updateExpr (VarE t var) = VarE t (updateVar var)
    updateExpr e = e
      

updateDescrs :: (LVarDescr -> LVarDescr) -> Node -> Node
updateDescrs update node = node { nodeVars = nodeVars' }
  where nodeVars' = Map.map update (nodeVars node)


elimGVars :: [NodeId] -> Node -> Node
elimGVars mergedIds node = updateDescrs update node
  where update d
          | LVarDescr t (Ext (GVar n lvar)) <- d, n `elem` mergedIds =
            LVarDescr t $ Expr $ VarE t $ n `prefix` lvar
          | otherwise = d


renameGVars :: (GVar -> GVar) -> Node -> Node
renameGVars rename node = updateDescrs update node
  where update (LVarDescr t (Ext gvar)) = LVarDescr t $ Ext $ rename gvar
        update d = d


unsafeMerge :: NodeId -> [Node] -> Node
unsafeMerge id nodes =
  Node id nodeDependencies' nodeVars'
  where
    nodeDependencies' = nub [id | n <- nodes
                                , id <- nodeDependencies n
                                , not $ id `elem` (map nodeId nodes)]
                        
    nodeVars' = foldl Map.union Map.empty (map nodeVars nodes)
    
--------------------------------------------------------------------------------

mergeNodes ::  [NodeId] -> [Node] -> [Node]
mergeNodes toMergeIds nodes =
  newNode : map (updateDeps . renameGVars renameG) otherNodes
  
  where decorateLVars n = renameLVars (prefix (nodeId n)) n
        
        (toMerge, otherNodes) = partition ((`elem` toMergeIds) . nodeId) nodes

        newNodeId = intercalate "-" toMergeIds
        
        renameG (GVar n lvar)
          | n `elem` toMergeIds = GVar newNodeId (prefix n lvar)
          | otherwise = GVar n lvar

        updateDeps n = n { nodeDependencies = update $ nodeDependencies n }
          where update ds =
                  let ds' = ds \\ toMergeIds in
                  if length ds' < length ds then newNodeId : ds' else ds
        
        newNode = elimGVars toMergeIds $
                  unsafeMerge newNodeId (map decorateLVars toMerge)


--------------------------------------------------------------------------------

linearize :: Spec -> Spec
linearize spec = spec { specNodes = update (specNodes spec) }
  where update ns = setId "top" <$> mergeNodes (map nodeId ns) ns
        setId id n = n { nodeId = id }

removeCycles :: Spec -> Spec
removeCycles spec = spec { specNodes = update (specNodes spec) }
  where update ns =
          let scc = buildScc nodeId ns
            
              mergeComp (Graph.AcyclicSCC _) ns = ns
              mergeComp (Graph.CyclicSCC ids) ns =
                mergeNodes ids ns
            
          in topoSort $ foldr mergeComp ns scc

        buildScc nrep ns =
          let depGraph = map (\n -> (nrep n, nodeId n, nodeDependencies n)) ns
          in Graph.stronglyConnComp depGraph

        topoSort ns = map (\(Graph.AcyclicSCC n) -> n) $ buildScc id ns
          

        


-- | Completes each node of a specification with imported variables such
-- | that each node contains a copy of all its dependencies
-- | The given specification should have its node sorted by topological
-- | order.
-- | Note that the last node will contain all the needed variables to
-- | characterize the whole system

complete :: Spec -> Spec
complete spec = spec { specNodes = specNodes' }
   
  where

    specNodes' = reverse . foldl completeNode [] . specNodes $ spec
    
    -- Takes a list of nodes 'ns', 'n' whose dependencies are in 'ns', and
    -- returns 'n2:ns' where 'n2' is 'n' completed
    completeNode :: [Node] -> Node -> [Node]
    completeNode ns n = (n { nodeVars = nodeVars' }) : ns

      where dummyVars = do
              depId <- nodeDependencies n
              let Just dep = find ((== depId) . nodeId) ns
              (lvar, LVarDescr t _) <- Map.toList (nodeVars dep)
              let gvar = GVar depId lvar              
              guard . not $ gvar `elem` curExtVars
              return (depId `prefix` lvar, LVarDescr t $ Ext gvar)

            curExtVars = do
              (_, LVarDescr _ (Ext gvar)) <- Map.toList (nodeVars n)
              return gvar

            nodeVars' = Map.union (nodeVars n) (Map.fromList dummyVars)
              

          
--------------------------------------------------------------------------------

