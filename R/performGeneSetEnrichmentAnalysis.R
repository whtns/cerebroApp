#' Perform gene set enrichment analysis with GSVA.
#' @title Perform gene set enrichment analysis with GSVA.
#' @description This function calculates enrichment scores, p- and q-value
#' statistics for provided gene sets for samples and clusters of cells in given
#' Seurat object using gene set variation analysis (GSVA). Calculation of p- and
#' q-values for gene sets is performed as done in "Evaluation of methods to
#' assign cell type labels to cell clusters from single-cell RNA-sequencing
#' data", Diaz-Mejia et al., F1000Research (2019).
#' @keywords Cerebro scRNAseq Seurat GSVA
#' @param object Seurat object.
#' @param assay Assay to pull counts from; defaults to 'RNA'. Only relevant in
#' Seurat v3.0 or higher since the concept of assays wasn't implemented before.
#' @param GMT_file Path to GMT file containing the gene sets to be tested.
#' The Broad Institute provides many gene sets which can be downloaded:
#' http://software.broadinstitute.org/gsea/msigdb/index.jsp
#' @param column_sample Column in object@meta.data that contains information
#' about sample; defaults to 'sample'.
#' @param column_cluster Column in object@meta.data that contains information
#' about cluster; defaults to 'cluster'.
#' @param thresh_p_val Threshold for p-value, defaults to 0.05.
#' @param thresh_q_val Threshold for q-value, defaults to 0.1.
#' @param ... Further parameters can be passed to control GSVA::gsva().
#' @export
#' @return Seurat object with GSVA results for samples and clusters stored in
#' object@misc$enriched_pathways$GSVA.
#' @import dplyr
#' @importFrom GSVA gsva
#' @importFrom Matrix colSums
#' @importFrom qvalue qvalue
#' @importFrom rlang .data
#' @importFrom tibble tibble
#' @examples
#' pbmc <- readRDS(system.file("extdata/v1.2/seurat_pbmc.rds",
#'   package = "cerebroApp"))
#' example_gene_set <- system.file("extdata/example_gene_set.gmt",
#'   package = "cerebroApp")
#' pbmc <- performGeneSetEnrichmentAnalysis(
#'   object = pbmc,
#'   GMT_file = example_gene_set,
#'   column_sample = 'sample',
#'   column_cluster = 'seurat_clusters',
#'   thresh_p_val = 0.05,
#'   thresh_q_val = 0.1,
#'   parallel.sz = 1,
#'   verbose = FALSE
#' )
performGeneSetEnrichmentAnalysis <- function(
  object,
  assay = 'RNA',
  GMT_file,
  column_sample = 'sample',
  column_cluster = 'cluster',
  thresh_p_val = 0.05,
  thresh_q_val = 0.1,
  ...
)
{
  ## check if Seurat is installed
  if (!requireNamespace("Seurat", quietly = TRUE))
  {
    stop(
      "Package 'Seurat' needed for this function to work. Please install it.",
      call. = FALSE
    )
  }
  ##---------------------------------------------------------------------------#
  ## check input parameters
  ##---------------------------------------------------------------------------#
  if ( !file.exists(GMT_file) )
  {
    stop("Specified GMT file with gene sets cannot be found.", call. = FALSE)
  }
  if ( (column_sample %in% colnames(object@meta.data)) == FALSE )
  {
    stop("Specified sample column doesn't exist in meta data.", call. = FALSE)
  }
  if ( (column_cluster %in% colnames(object@meta.data)) == FALSE )
  {
    stop("Specified cluster column doesn't exist in meta data.", call. = FALSE)
  }
  if ( thresh_p_val < 0 | thresh_p_val > 1 )
  {
    stop(
      "Specified threshold for p-value must be between 0 and 1.",
      call. = FALSE
    )
  }
  if ( thresh_q_val < 0 | thresh_q_val > 1 )
  {
    stop(
      "Specified threshold for q-value must be between 0 and 1.",
      call. = FALSE
    )
  }

  ##---------------------------------------------------------------------------#
  ## preparation
  ##---------------------------------------------------------------------------#
  ## load gene sets from GMT file
  message(
    paste0(
      '[', format(Sys.time(), '%H:%M:%S'), '] Loading gene sets...'
    )
  )
  gene_sets <- .read_GMT_file(GMT_file)

  names(gene_sets$genesets) <- gene_sets$geneset.names

  ## make tibble that contains name, description and list of genes for each set
  gene_sets_tibble <- tibble::tibble(
      name = gene_sets$geneset.names,
      description = gene_sets$geneset.description,
      length = NA,
      genes = NA
    )

  for ( i in seq_len(length(gene_sets$genesets)) )
  {
    gene_sets_tibble$length[i] <- gene_sets$genesets[[i]] %>% length()
    gene_sets_tibble$genes[i] <- gene_sets$genesets[[i]] %>%
      unlist() %>%
      paste(.data, collapse = ',')
  }

  message(
    paste0(
      '[', format(Sys.time(), '%H:%M:%S'), '] Loaded ',
      length(gene_sets$genesets), ' gene sets from GMT file.'
    )
  )

  ## extract transcript count matrix (log-scale) from Seurat object
  message(
    paste0(
      '[', format(Sys.time(), '%H:%M:%S'), '] Extracting transcript counts...'
    )
  )
  if ( object@version < 3 )
  {
    ## check if `data` matrix exist in provided Seurat object
    if ( is.null(object@data) )
    {
      stop(
        paste0(
          '`data` matrix could not be found in provided Seurat ',
          'object.'
        ),
        call. = FALSE
      )
    }
    matrix_full <- object@data %>%
      as.matrix() %>%
      t() %>%
      as.data.frame()
  } else
  {
    ## check if provided assay exists
    if ( (assay %in% names(object@assays) == FALSE ) )
    {
      stop(
        paste0(
          'Assay slot `', assay, '` could not be found in provided Seurat ',
          'object.'
        ),
        call. = FALSE
      )
    }
    ## check if `data` matrix exist in provided assay
    if ( is.null(object@assays[[assay]]@data) )
    {
      stop(
        paste0(
          '`data` matrix could not be found in `', assay, '` assay slot.'
        ),
        call. = FALSE
      )
    }
    matrix_full <- object@assays[[assay]]@data %>%
      as.matrix() %>%
      t() %>%
      as.data.frame()
  }

  ## remove genes with zero counts across all cells
  message(
    paste0(
      '[', format(Sys.time(), '%H:%M:%S'), '] Removing non-expressed genes...'
    )
  )
  expressed_genes <- matrix_full %>%
    Matrix::colSums()
  expressed_genes <- which(expressed_genes != 0)
  matrix_full <- matrix_full[,expressed_genes]

  ##---------------------------------------------------------------------------#
  ## workflow for samples
  ##---------------------------------------------------------------------------#
  if ( object@meta.data[[column_sample]] %>% unique() %>% length() > 1 ) {
    message(
      paste0(
        '[', format(Sys.time(), '%H:%M:%S'), '] Performing GSVA for samples...'
      )
    )

    ## get sample names
    if ( is.factor(object@meta.data[[column_sample]]) )
    {
      sample_names <- levels(object@meta.data[[column_sample]])
    } else
    {
      sample_names <- unique(object@meta.data[[column_sample]])
    }

    ## add group information as column to expression matrix
    temp_matrix_full <- matrix_full %>%
      dplyr::mutate(group = object@meta.data[[column_sample]])

    ## calculate mean log counts per group of cells
    matrix_merged <- temp_matrix_full %>%
      dplyr::group_by(.data$group) %>%
      dplyr::summarise_all(mean)

    ## keep order of groups for later
    groups <- matrix_merged$group

    ## remove group information from count matrix and transpose for GSVA
    matrix_merged <- matrix_merged %>%
      dplyr::select(-'group') %>%
      as.matrix() %>%
      t()

    ## add group info back to count matrix as column names
    colnames(matrix_merged) <- groups

    ## get enrichment score for each gene set in every cell group
    enrichment_scores <- GSVA::gsva(
        expr = matrix_merged,
        gset.idx.list = gene_sets$genesets,
        ...
      )

    ## calculate statistics for enrichment scores and filter those which don't
    ## pass the specified tresholds
    message(
      paste0(
        '[', format(Sys.time(), '%H:%M:%S'), '] Filtering results based on ',
        'specified thresholds...'
      )
    )
    results_by_sample <- tibble::tibble(
        group = character(),
        name = character(),
        enrichment_score = numeric(),
        p_value = numeric(),
        q_value = numeric()
      )
    for ( i in seq_len(ncol(enrichment_scores)) )
    {
      temp_results <- tibble::tibble(
          group = colnames(matrix_merged)[i],
          name = rownames(enrichment_scores),
          enrichment_score = enrichment_scores[,i]
        )
      if ( nrow(temp_results) < 2 )
      {
        message(
          paste0(
            '[', format(Sys.time(), '%H:%M:%S'), '] Only 1 gene set ',
            'available, therefore no p- and q-values can be calculated and no ',
            'filtering of the results will be performed.'
          )
        )
        temp_results <- temp_results %>%
          dplyr::mutate(p_value = NA, q_value = NA)
      } else
      {
        message(
          paste0(
            '[', format(Sys.time(), '%H:%M:%S'), '] Filtering results based on ',
            'specified thresholds...'
          )
        )
        temp_results <- temp_results %>%
          dplyr::mutate(
            p_value = stats::pnorm(-abs(scale(.data$enrichment_score)[,1])),
            q_value = qvalue::qvalue(.data$p_value, pi0 = 1)$lfdr
          ) %>%
          dplyr::filter(
            .data$p_value <= thresh_p_val,
            .data$q_value <= thresh_q_val
          )
      }
      results_by_sample <- dplyr::bind_rows(results_by_sample, temp_results) %>%
        dplyr::arrange(.data$q_value)
    }

    ## add description, number of genes and list of genes to results
    results_by_sample <- dplyr::left_join(
        results_by_sample,
        gene_sets_tibble,
        by = 'name'
      ) %>%
      dplyr::select(c('group','name','description','length','genes',
        'enrichment_score','p_value','q_value')) %>%
      dplyr::mutate(group = factor(.data$group, levels = intersect(sample_names,
        .data$group)))

    ## print number of enriched gene sets
    message(
      paste0(
        '[', format(Sys.time(), '%H:%M:%S'), '] ', nrow(results_by_sample),
        ' gene sets passed the thresholds across all samples.'
      )
    )

    ## test if any gene sets passed the filtering
    if ( nrow(results_by_sample) == 0 )
    {
      results_by_sample <- 'no_gene_sets_enriched'
    }
  } else
  {
    message(
      paste0(
        '[', format(Sys.time(), '%H:%M:%S'), '] Only 1 sample in the data ',
        'set, will skip analysis by sample...'
      )
    )
    results_by_sample <- 'only_one_sample_in_data_set'
  }

  ##---------------------------------------------------------------------------#
  ## workflow for clusters
  ##---------------------------------------------------------------------------#
  if ( object@meta.data[[column_cluster]] %>% unique() %>% length() > 1 )
  {
    message(
      paste0(
        '[', format(Sys.time(), '%H:%M:%S'), '] Performing GSVA for clusters...'
      )
    )

    ## get cluster names
    if ( is.factor(object@meta.data[[column_cluster]]) )
    {
      cluster_names <- levels(object@meta.data[[column_cluster]])
    } else
    {
      cluster_names <- unique(object@meta.data[[column_cluster]])
    }

    ## add group information as column to expression matrix
    temp_matrix_full <- matrix_full %>%
      dplyr::mutate(group = object@meta.data[[column_cluster]])

    ## calculate mean log counts per group of cells
    matrix_merged <- temp_matrix_full %>%
      dplyr::group_by(.data$group) %>%
      dplyr::summarise_all(mean)

    ## keep order of groups for later
    groups <- matrix_merged$group

    ## remove group information from count matrix and transpose for GSVA
    matrix_merged <- matrix_merged %>%
      dplyr::select(-'group') %>%
      as.matrix() %>%
      t()

    ## add group info back to count matrix as column names
    colnames(matrix_merged) <- groups

    ## get enrichment score for each gene set in every cell group
    enrichment_scores <- GSVA::gsva(
        expr = matrix_merged,
        gset.idx.list = gene_sets$genesets,
        ...
      )

    ## calculate statistics for enrichment scores and filter those which don't
    ## pass the specified tresholds
    results_by_cluster <- tibble::tibble(
        group = character(),
        name = character(),
        enrichment_score = numeric(),
        p_value = numeric(),
        q_value = numeric()
      )
    for ( i in seq_len(ncol(enrichment_scores)) )
    {
      temp_results <- tibble::tibble(
          group = colnames(matrix_merged)[i],
          name = rownames(enrichment_scores),
          enrichment_score = enrichment_scores[,i]
        )
      if ( nrow(temp_results) < 2 )
      {
        message(
          paste0(
            '[', format(Sys.time(), '%H:%M:%S'), '] Only 1 gene set ',
            'available, therefore no p- and q-values can be calculated and no ',
            'filtering of the results will be performed.'
          )
        )
        temp_results <- temp_results %>%
          dplyr::mutate(p_value = NA, q_value = NA)
      } else
      {
        message(
          paste0(
            '[', format(Sys.time(), '%H:%M:%S'), '] Filtering results based on ',
            'specified thresholds...'
          )
        )
        temp_results <- temp_results %>%
          dplyr::mutate(
            p_value = stats::pnorm(-abs(scale(.data$enrichment_score)[,1])),
            q_value = qvalue::qvalue(.data$p_value, pi0 = 1)$lfdr
          ) %>%
          dplyr::filter(
            .data$p_value <= thresh_p_val,
            .data$q_value <= thresh_q_val
          )
      }
      results_by_cluster <- dplyr::bind_rows(
          results_by_cluster,
          temp_results
        ) %>%
        dplyr::arrange(.data$q_value)
    }

    ## add description, number of genes and list of genes to results
    results_by_cluster <- dplyr::left_join(
        results_by_cluster,
        gene_sets_tibble,
        by = 'name'
      ) %>%
      dplyr::select(c('group','name','description','length','genes',
        'enrichment_score','p_value','q_value')) %>%
      dplyr::mutate(group = factor(.data$group, levels = intersect(
        cluster_names, .data$group)))

    ## print number of enriched gene sets
    message(
      paste0(
        '[', format(Sys.time(), '%H:%M:%S'), '] ', nrow(results_by_cluster),
        ' gene sets passed the thresholds across all clusters.'
      )
    )

    ## test if any gene sets passed the filtering
    if ( nrow(results_by_cluster) == 0 )
    {
      results_by_cluster <- 'no_gene_sets_enriched'
    }
  } else
  {
    message(
      paste0(
        '[', format(Sys.time(), '%H:%M:%S'), '] Only 1 cluster in the data ',
        'set, will skip analysis by cluster...'
      )
    )
    results_by_cluster <- 'only_one_cluster_in_data_set'
  }

  ##---------------------------------------------------------------------------#
  ## merge results, add to Seurat object and return Seurat object
  ##---------------------------------------------------------------------------#
  results <- list(
    by_sample = results_by_sample,
    by_cluster = results_by_cluster,
    parameters = list(
      GMT_file = basename(GMT_file),
      thresh_p_val = thresh_p_val,
      thresh_q_val = thresh_q_val
    )
  )
  object@misc$enriched_pathways$GSVA <- results
  return(object)
}

