#' @describeIn mmDS
#' 
#' A SCE wrapper around the voom-lme4-implementation 
#' \code{\link[variancePartition]{dream}} of mixed models for RNAseq data. 
#' \code{.mm_dream} expects cells from a single cluster, and
#' does not perform filtering or handle incorrect parameters well.
#' Meant to be called by \code{mmDS} with \code{method = "dream"}
#' to be applied across all clusters.
#' 
#' @param dup_corr logical; whether to use 
#'   \code{\link[limma]{duplicateCorrelation}}.
#'   
#' @importFrom edgeR DGEList
#' @importFrom doParallel registerDoParallel
#' @importFrom dplyr %>% last mutate_at rename
#' @importFrom limma duplicateCorrelation eBayes topTable voom
#' @importFrom magrittr set_rownames
#' @importFrom matrixStats rowSds
#' @importFrom parallel makeCluster stopCluster
#' @importFrom scran computeSumFactors
#' @importFrom SingleCellExperiment counts sizeFactors
#' @importFrom stats as.formula model.matrix
#' @importFrom variancePartition dream getContrast
.mm_dream <- function(x, coef, covs, n_threads, verbose, 
    dup_corr = FALSE) {
    if (is.null(sizeFactors(x)))
        x <- computeSumFactors(x)
    
    x <- x[rowSds(as.matrix(counts(x))) > 0, ]
    y <- DGEList(counts(x), norm.factors = 1 / sizeFactors(x))
    
    cd <- .prep_cd(x, covs)
    
    formula <- paste0("~", paste(c(covs, "group_id"), collapse = "+"))
    mm <- model.matrix(as.formula(formula), data = cd)
    v <- voom(y, mm)
    
    if (dup_corr) {
        dup_corr <- duplicateCorrelation(v, mm, block = x$sample_id)
        v <- voom(y, mm, block = x$sample_id, correlation = dup_corr$consensus)
    }
    
    if (n_threads > 1) {
        cl <- makeCluster(n_threads)
        registerDoParallel(cl)
    }
    
    formula <- paste0(formula, "+(1|sample_id)")
    if (verbose) print(formula)
    
    if (is.null(coef)) {
        coef <- last(colnames(mm))
        if (verbose) 
            message("Argument 'coef' not specified; ", 
                sprintf("testing for %s.", dQuote(coef)))
    }
    
    contrast <- getContrast(v, as.formula(formula), cd, coef)
    fit <- dream(v, formula, cd, contrast, ddf = "Satterthwaite")
    fit <- eBayes(fit)
    if (n_threads > 1) stopCluster(cl)
    
    topTable(fit, number = Inf, sort.by = "none") %>% 
        rename(p_val = "P.Value", p_adj.loc = "adj.P.Val")
}

#' @describeIn mmDS
#' 
#' A SCE wrapper around \code{\link[DESeq2]{varianceStabilizingTransformation}} 
#' followed by \code{lme4} mixed models. 
#' \code{.mm_vst} expects cells from a single cluster, and 
#' does not perform filtering or handle incorrect parameters well. 
#' Meant to be called by \code{mmDS} with \code{method = "vst"}
#' to be applied across all clusters.
#' 
#' @param blind logical; whether to ignore experimental design for the vst.
#' @param REML logical; whether to maximize REML instead of log-likelihood.
#'
#' @importFrom DESeq2 DESeqDataSetFromMatrix estimateDispersions 
#'   sizeFactors varianceStabilizingTransformation
#' @importFrom dplyr last
#' @importFrom lme4 lmer
#' @importFrom lmerTest contest
#' @importFrom magrittr set_colnames
#' @importFrom SingleCellExperiment counts sizeFactors sizeFactors<-
#' @importFrom SummarizedExperiment assay
#' @importFrom stats p.adjust
.mm_vst <- function(x, coef, covs, n_threads, verbose, 
    blind = TRUE, REML = TRUE) {
    
    if (is.null(sizeFactors(x)))
        x <- computeSumFactors(x)
    
    cd <- .prep_cd(x, covs)
    formula <- paste0("~", paste(c(covs, "sample_id"), collapse="+"))
    formula <- as.formula(formula)
    y <- DESeqDataSetFromMatrix(as.matrix(counts(x)), cd, formula)
    
    sizeFactors(y) <- sizeFactors(x)
    if (!blind) y <- estimateDispersions(y)
    vst <- varianceStabilizingTransformation(y, blind)
    
    formula <- paste0("~(1|sample_id)+", 
        paste(c(covs, "group_id"), collapse="+"))
    if (verbose) print(formula)
    formula <- as.formula(paste0("u", formula))
    
    if (is.null(coef)) {
        gids <- levels(x$group_id)
        coef <- paste0("group_id", last(gids))
        if (verbose) 
            message("Argument 'coef' not specified; ", 
                sprintf("testing for %s.", dQuote(coef)))
    }
    
    res <- apply(assay(vst), 1, function(u) {
        df <- data.frame(u, cd)
        fit <- lmer(formula, df, REML)
        sum <- summary(fit)$coef
        cvec <- as.numeric(rownames(sum) == coef)
        res <- contest(fit, cvec)[, c("F value", "Pr(>F)")]
        data.frame(sum[coef, 1], res)
    })
    res <- bind_rows(res) %>% set_colnames(c(coef, "F", "p_val"))
    res$p_adj.loc <- p.adjust(res$p_val, method = "BH")
    return(res)
} 

# helper to prepare colData for .mm_dream/vst
#' @importFrom dplyr %>% mutate_at
#' @importFrom methods is
#' @importFrom magrittr set_rownames
#' @importFrom SummarizedExperiment colData
.prep_cd <- function(x, covs) {
    cd <- colData(x)[c("sample_id", "group_id", covs)]
    data.frame(cd, check.names = FALSE) %>% 
        mutate_at(covs, function(u) if (is.numeric(u)) scale(u)) %>% 
        set_rownames(colnames(x))
}