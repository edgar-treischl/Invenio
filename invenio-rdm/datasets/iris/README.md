# Iris Flower Dataset

**Source:** UCI Machine Learning Repository
**Original paper:** Fisher, R.A. (1936). *The use of multiple measurements in taxonomic problems.* Annals of Eugenics, 7(2), 179–188.
**License:** CC BY 4.0

## Description

150 observations of Iris flower morphometrics across three species:

| Species | Count |
|---------|-------|
| *Iris setosa* | 50 |
| *Iris versicolor* | 50 |
| *Iris virginica* | 50 |

## File contents

| File | Description |
|------|-------------|
| `data.csv` | 150 rows × 5 columns (see schema below) |
| `schema.json` | JSON Schema describing column types and units |
| `metadata.json` | InvenioRDM record metadata (used for ingestion) |
| `checksums.txt` | SHA-256 checksums for fixity verification |

## Schema

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `sepal_length` | float | cm | Length of the sepal |
| `sepal_width` | float | cm | Width of the sepal |
| `petal_length` | float | cm | Length of the petal |
| `petal_width` | float | cm | Width of the petal |
| `species` | string | — | Iris species (setosa / versicolor / virginica) |

## Fixity

Run `sha256sum -c checksums.txt` to verify file integrity.
