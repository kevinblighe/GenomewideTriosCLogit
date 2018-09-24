clogitParallel <- function(
  data,
  formula.list,
  FUN,
  variables,
  terms,
  startIndex,
  blocksize,
  blocks,
  system,
  cluster,
  nestedParallel,
  conflevel,
  excludeTerms)
{
  foreach(l = 1:blocks, .combine = rbind, .multicombine = TRUE, .inorder = FALSE, .packages = c("data.table", "doParallel", "parallel", "doMC", "foreach", "BiocParallel")) %dopar% {

    # first block - will be executed just once
    if (l==1) {
      message(paste("Processing ", blocksize, " formulae, batch ", l, " of ", blocks, sep=""))
      message(paste("-- index1: 1; ", "index2: ", (blocksize*l), sep=""))

      df <- data[,c(which(colnames(data) %in% terms), startIndex + (1:(blocksize*l)))]

      if (nestedParallel == TRUE) {
        if (system == "Windows") {
            models <- parLapply(cl, formula.list[1:(blocksize*l)], function(f) summary(FUN(formula = f, data = df)))
        } else {
            models <- mclapply(formula.list[1:(blocksize*l)], function(f) summary(FUN(formula = f, data = df)))
        }
      } else if (nestedParallel == FALSE) {
        models <- lapply(formula.list[1:(blocksize*l)], function(f) summary(FUN(formula = f, data = df)))
      } else {
        stop("Invalid value for argument nestedParallel. Must be TRUE/FALSE")
      }

      names(models) <- variables[1:(blocksize*l)]

      # detect failed models (return 'try' error)
      nullindices <- c(
        which(mapply(inherits, models, 'try-error'))
      )
      if (length(nullindices) > 1) {
        print(models[[nullindices[1]]][1])
        stop(paste('\nOne or more models have failed. ',
          'Please recheck your data and model formula', sep=''))
      }

      # extract coefficients and convert to data-frame
      if (system == "Windows") {
        wObjects <- parLapply(cl, names(models), function(x) data.frame(models[[x]]['coefficients']))
      } else {
        wObjects <- mclapply(names(models), function(x) data.frame(models[[x]]['coefficients']))
      }

      names(wObjects) <- variables[1:(blocksize*l)]

      # further processing
      if (system == "Windows") {
        wObjects <- parLapply(cl, names(wObjects), function(x) data.frame(rep(x, length(rownames(wObjects[[x]]))), rownames(wObjects[[x]]), wObjects[[x]], row.names=rownames(wObjects[[x]])))
      } else {
        wObjects <- mclapply(names(wObjects), function(x) data.frame(rep(x, length(rownames(wObjects[[x]]))), rownames(wObjects[[x]]), wObjects[[x]], row.names=rownames(wObjects[[x]])))
      }

      # extract p values specific to coxph
      if (system == "Windows") {
        p <- parLapply(cl, names(models), function(x) data.frame(models[[x]]$logtest, models[[x]]$waldtest, models[[x]]$sctest)["pvalue",])
      } else {
        p <- mclapply(names(models), function(x) data.frame(models[[x]]$logtest, models[[x]]$waldtest, models[[x]]$sctest)["pvalue",])
      }

      # remove specified terms from the output
      # Nota bene - intercept not relevant for Cox models
      if (!is.null(excludeTerms) ) {
        if (system == "Windows") {
          wObjects <- parLapply(cl, wObjects, function(x) x[grep(paste(c(excludeTerms), collapse="|"), rownames(x), invert=TRUE),])
        } else {
          wObjects <- mclapply(wObjects, function(x) x[grep(paste(c(excludeTerms), collapse="|"), rownames(x), invert=TRUE),])
        }
      }

      # check the final number of terms and multiple the coxph-specific p-value data-frame rows by these
      # as there is only one of these p-values per model, we have to duplicate them to fit alongside the respective model terms in the final data-table
      nterms <- nrow(wObjects[[1]])
      if (system == "Windows") {
        p <- parLapply(cl, p, function(x) x[rep('pvalue', nterms),])
      } else {
        p <- mclapply(p, function(x) x[rep('pvalue', nterms),])
      }

      #Convert the list into a data table
      wObjects <- data.table(rbindlist(wObjects), rbindlist(p), stringsAsFactors=FALSE)

      # set colnames
      colnames(wObjects) <- c("Variable", "Term", "Beta", "ExpBeta", "StandardError", "Z", "P", "LRT", "Wald", "LogRank")

      wObjects$Variable <- as.character(wObjects$Variable)
      wObjects$Beta <- as.numeric(as.character(wObjects$Beta))
      wObjects$StandardError <- as.numeric(as.character(wObjects$StandardError))
      wObjects$Z <- as.numeric(as.character(wObjects$Z))
      wObjects$P <- as.numeric(as.character(wObjects$P))

      # calculate HR and confidence intervals
      #wObjects$HR <- exp(wObjects[,'Beta'])
      wObjects$HR <- wObjects$ExpBeta
      wObjects$HRlower <- wObjects$HR * exp(qnorm(((1 - (conflevel / 100)) / 2)) * wObjects$StandardError)
      wObjects$HRupper <- wObjects$HR * exp(qnorm(1 - ((1 - (conflevel / 100)) / 2)) * wObjects$StandardError)

      # change Inf and NaN to NA
      wObjects$Z[is.infinite(wObjects$Z)] <- NA
      wObjects$Z[wObjects$Z == "NaN"] <- NA
      wObjects$P[is.infinite(wObjects$P)] <- NA
      wObjects$P[wObjects$P == "NaN"] <- NA
      wObjects$HR[is.infinite(wObjects$HR)] <- NA
      wObjects$HR[wObjects$HR == "NaN"] <- NA
      wObjects$HRlower[is.infinite(wObjects$HRlower)] <- NA
      wObjects$HRlower[wObjects$HRlower == "NaN"] <- NA
      wObjects$HRupper[is.infinite(wObjects$HRupper)] <- NA
      wObjects$HRupper[wObjects$HRupper == "NaN"] <- NA
      
      # if on Windows and there's only 1 block, then this is the first and final block
      # thus, we must free the cluster
      if ((blocks == 1) && (system == 'Windows')) {
        stopCluster(cl)
      }

      return(wObjects[,ExpBeta:=NULL])
    }

    # final block - will be executed just once
    if (l==blocks) {
      message(paste("Processing final batch ", l, " of ", blocks, sep=""))
      message(paste("-- index1: ", (1+(blocksize*(l-1))), "; ", "index2: ", length(formula.list), sep=""))
      df <- data[,c(which(colnames(data) %in% terms), startIndex + (((1+(blocksize*(l-1)))):(length(formula.list))))]

      if (nestedParallel == TRUE) {
        if (system == "Windows") {
          models <- parLapply(cl, formula.list[(1+(blocksize*(l-1))):length(formula.list)], function(f) summary(FUN(formula = f, data = df))$coefficients)
        } else {
          models <- mclapply(formula.list[(1+(blocksize*(l-1))):length(formula.list)], function(f) summary(FUN(formula = f, data = df)))
        }
      } else if (nestedParallel == FALSE) {
        models <- lapply(formula.list[(1+(blocksize*(l-1))):length(formula.list)], function(f) summary(FUN(formula = f, data = df)))
      } else {
        stop("Invalid value for argument nestedParallel. Must be TRUE/FALSE")
      }

      names(models) <- variables[(1+(blocksize*(l-1))):length(formula.list)]

      # detect failed models (return 'try' error)
      nullindices <- c(
        which(mapply(inherits, models, 'try-error'))
      )
      if (length(nullindices) > 1) {
        print(models[[nullindices[1]]][1])
        stop(paste('\nOne or more models have failed. ',
          'Please recheck your data and model formula', sep=''))
      }

      # extract coefficients and convert to data-frame
      if (system == "Windows") {
        wObjects <- parLapply(cl, names(models), function(x) data.frame(models[[x]]['coefficients']))
      } else {
        wObjects <- mclapply(names(models), function(x) data.frame(models[[x]]['coefficients']))
      }

      names(wObjects) <- variables[(1+(blocksize*(l-1))):length(formula.list)]

      # further processing
      if (system == "Windows") {
        wObjects <- parLapply(cl, names(wObjects), function(x) data.frame(rep(x, length(rownames(wObjects[[x]]))), rownames(wObjects[[x]]), wObjects[[x]], row.names=rownames(wObjects[[x]])))
      } else {
        wObjects <- mclapply(names(wObjects), function(x) data.frame(rep(x, length(rownames(wObjects[[x]]))), rownames(wObjects[[x]]), wObjects[[x]], row.names=rownames(wObjects[[x]])))
      }

      # extract p values specific to coxph
      if (system == "Windows") {
        p <- parLapply(cl, names(models), function(x) data.frame(models[[x]]$logtest, models[[x]]$waldtest, models[[x]]$sctest)["pvalue",])
      } else {
        p <- mclapply(names(models), function(x) data.frame(models[[x]]$logtest, models[[x]]$waldtest, models[[x]]$sctest)["pvalue",])
      }

      # remove specified terms from the output
      # Nota bene - intercept not relevant for Cox models
      if (!is.null(excludeTerms) ) {
        if (system == "Windows") {
          wObjects <- parLapply(cl, wObjects, function(x) x[grep(paste(c(excludeTerms), collapse="|"), rownames(x), invert=TRUE),])
        } else {
          wObjects <- mclapply(wObjects, function(x) x[grep(paste(c(excludeTerms), collapse="|"), rownames(x), invert=TRUE),])
        }
      }

      # check the final number of terms and multiple the coxph-specific p-value data-frame rows by these
      # as there is only one of these p-values per model, we have to duplicate them to fit alongside the respective model terms in the final data-table
      nterms <- nrow(wObjects[[1]])
      if (system == "Windows") {
        p <- parLapply(cl, p, function(x) x[rep('pvalue', nterms),])
      } else {
        p <- mclapply(p, function(x) x[rep('pvalue', nterms),])
      }

      #Convert the list into a data table
      wObjects <- data.table(rbindlist(wObjects), rbindlist(p), stringsAsFactors=FALSE)

      # set colnames
      colnames(wObjects) <- c("Variable", "Term", "Beta", "ExpBeta", "StandardError", "Z", "P", "LRT", "Wald", "LogRank")

      wObjects$Variable <- as.character(wObjects$Variable)
      wObjects$Beta <- as.numeric(as.character(wObjects$Beta))
      wObjects$StandardError <- as.numeric(as.character(wObjects$StandardError))
      wObjects$Z <- as.numeric(as.character(wObjects$Z))
      wObjects$P <- as.numeric(as.character(wObjects$P))

      # calculate HR and confidence intervals
      #wObjects$HR <- exp(wObjects[,'Beta'])
      wObjects$HR <- wObjects$ExpBeta
      wObjects$HRlower <- wObjects$HR * exp(qnorm(((1 - (conflevel / 100)) / 2)) * wObjects$StandardError)
      wObjects$HRupper <- wObjects$HR * exp(qnorm(1 - ((1 - (conflevel / 100)) / 2)) * wObjects$StandardError)

      # change Inf and NaN to NA
      wObjects$Z[is.infinite(wObjects$Z)] <- NA
      wObjects$Z[wObjects$Z == "NaN"] <- NA
      wObjects$P[is.infinite(wObjects$P)] <- NA
      wObjects$P[wObjects$P == "NaN"] <- NA
      wObjects$HR[is.infinite(wObjects$HR)] <- NA
      wObjects$HR[wObjects$HR == "NaN"] <- NA
      wObjects$HRlower[is.infinite(wObjects$HRlower)] <- NA
      wObjects$HRlower[wObjects$HRlower == "NaN"] <- NA
      wObjects$HRupper[is.infinite(wObjects$HRupper)] <- NA
      wObjects$HRupper[wObjects$HRupper == "NaN"] <- NA

      # final block. If Windows system, disable access to grabbed cluster
      if (system == 'Windows') {
        stopCluster(cl)
      }

      return(wObjects[,ExpBeta:=NULL])
    }

    # any other blocks - executed any number of times between first and final block
    if (l>1 && l<blocks) {
      message(paste("Processing ", blocksize, " formulae, batch ", l, " of ", blocks, sep=""))
      message(paste("-- index1: ", (1+(blocksize*(l-1))), "; ", "index2: ", (blocksize*l), sep=""))
      df <- data[,c(which(colnames(data) %in% terms), startIndex + ((1+(blocksize*(l-1))):(blocksize*l)))]

      if (nestedParallel == TRUE) {
        if (system == "Windows") {
          models <- parLapply(cl, formula.list[(1+(blocksize*(l-1))):(blocksize*l)], function(f) summary(FUN(formula = f, data = df)))
        } else {
          models <- mclapply(formula.list[(1+(blocksize*(l-1))):(blocksize*l)], function(f) summary(FUN(formula = f, data = df)))
        } 
      } else if (nestedParallel == FALSE) {
        models <- lapply(formula.list[(1+(blocksize*(l-1))):(blocksize*l)], function(f) summary(FUN(formula = f, data = df)))
      } else {
        stop("Invalid value for argument nestedParallel. Must be TRUE/FALSE")
      }

      names(models) <- variables[(1+(blocksize*(l-1))):(blocksize*l)]

      # detect failed models (return 'try' error)
      nullindices <- c(
        which(mapply(inherits, models, 'try-error'))
      )
      if (length(nullindices) > 1) {
        print(models[[nullindices[1]]][1])
        stop(paste('\nOne or more models have failed. ',
          'Please recheck your data and model formula', sep=''))
      }

      # extract coefficients and convert to data-frame
      if (system == "Windows") {
        wObjects <- parLapply(cl, names(models), function(x) data.frame(models[[x]]['coefficients']))
      } else {
        wObjects <- mclapply(names(models), function(x) data.frame(models[[x]]['coefficients']))
      }

      names(wObjects) <- variables[(1+(blocksize*(l-1))):(blocksize*l)]

      # further processing
      if (system == "Windows") {
        wObjects <- parLapply(cl, names(wObjects), function(x) data.frame(rep(x, length(rownames(wObjects[[x]]))), rownames(wObjects[[x]]), wObjects[[x]], row.names=rownames(wObjects[[x]])))
      } else {
        wObjects <- mclapply(names(wObjects), function(x) data.frame(rep(x, length(rownames(wObjects[[x]]))), rownames(wObjects[[x]]), wObjects[[x]], row.names=rownames(wObjects[[x]])))
      }

      # extract p values specific to coxph
      if (system == "Windows") {
        p <- parLapply(cl, names(models), function(x) data.frame(models[[x]]$logtest, models[[x]]$waldtest, models[[x]]$sctest)["pvalue",])
      } else {
        p <- mclapply(names(models), function(x) data.frame(models[[x]]$logtest, models[[x]]$waldtest, models[[x]]$sctest)["pvalue",])
      }

      # remove specified terms from the output
      # Nota bene - intercept not relevant for Cox models
      if (!is.null(excludeTerms) ) {
        if (system == "Windows") {
          wObjects <- parLapply(cl, wObjects, function(x) x[grep(paste(c(excludeTerms), collapse="|"), rownames(x), invert=TRUE),])
        } else {
          wObjects <- mclapply(wObjects, function(x) x[grep(paste(c(excludeTerms), collapse="|"), rownames(x), invert=TRUE),])
        }
      }

      # check the final number of terms and multiple the coxph-specific p-value data-frame rows by these
      # as there is only one of these p-values per model, we have to duplicate them to fit alongside the respective model terms in the final data-table
      nterms <- nrow(wObjects[[1]])
      if (system == "Windows") {
        p <- parLapply(cl, p, function(x) x[rep('pvalue', nterms),])
      } else {
        p <- mclapply(p, function(x) x[rep('pvalue', nterms),])
      }

      #Convert the list into a data table
      wObjects <- data.table(rbindlist(wObjects), rbindlist(p), stringsAsFactors=FALSE)

      # set colnames
      colnames(wObjects) <- c("Variable", "Term", "Beta", "ExpBeta", "StandardError", "Z", "P", "LRT", "Wald", "LogRank")

      wObjects$Variable <- as.character(wObjects$Variable)
      wObjects$Beta <- as.numeric(as.character(wObjects$Beta))
      wObjects$StandardError <- as.numeric(as.character(wObjects$StandardError))
      wObjects$Z <- as.numeric(as.character(wObjects$Z))
      wObjects$P <- as.numeric(as.character(wObjects$P))

      # calculate HR and confidence intervals
      #wObjects$HR <- exp(wObjects[,'Beta'])
      wObjects$HR <- wObjects$ExpBeta
      wObjects$HRlower <- wObjects$HR * exp(qnorm(((1 - (conflevel / 100)) / 2)) * wObjects$StandardError)
      wObjects$HRupper <- wObjects$HR * exp(qnorm(1 - ((1 - (conflevel / 100)) / 2)) * wObjects$StandardError)

      # change Inf and NaN to NA
      wObjects$Z[is.infinite(wObjects$Z)] <- NA
      wObjects$Z[wObjects$Z == "NaN"] <- NA
      wObjects$P[is.infinite(wObjects$P)] <- NA
      wObjects$P[wObjects$P == "NaN"] <- NA
      wObjects$HR[is.infinite(wObjects$HR)] <- NA
      wObjects$HR[wObjects$HR == "NaN"] <- NA
      wObjects$HRlower[is.infinite(wObjects$HRlower)] <- NA
      wObjects$HRlower[wObjects$HRlower == "NaN"] <- NA
      wObjects$HRupper[is.infinite(wObjects$HRupper)] <- NA
      wObjects$HRupper[wObjects$HRupper == "NaN"] <- NA

      return(wObjects[,ExpBeta:=NULL])
    }
  }
}