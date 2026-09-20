# ============================================================
# TEMPLATE_BRS - Scan-Secrets.ps1
# ============================================================
# Auteur      : Sabri CHARCHOUF
# Date        : 31/07/2026
# Version     : 1.5
#
# Description :
#   Analyse tous les fichiers du projet et détecte les données
#   sensibles qui ne doivent JAMAIS être commitées sur GitHub.
#   Exécuté automatiquement via hook git pre-commit.
#
#   LOGIQUE SCAN :
#   - Scope 'ALL'  : Scanné partout (code ET commentaires)
#                    → Credentials, mots de passe, emails
#   - Scope 'CODE' : Scanné uniquement dans les lignes de code
#                    → Noms d'infra (clusters, ESXi, serveurs)
#                    → Evite les faux positifs dans .EXAMPLE, .DESCRIPTION
#
# Usage :
#   .\Scan-Secrets.ps1              -> scan complet
#   .\Scan-Secrets.ps1 -Verbose     -> détail complet
#   .\Scan-Secrets.ps1 -Fix         -> corrections suggérées
#
# Retourne :
#   Exit code 0 -> aucun secret CRITIQUE détecté (commit autorisé)
#   Exit code 1 -> secrets CRITIQUES détectés    (commit bloqué)
# ============================================================

param(
    [switch]$Verbose,
    [switch]$Fix
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# PATTERNS SENSIBLES
# Scope 'ALL'  = Scanné partout (code + commentaires)
# Scope 'CODE' = Scanné uniquement dans le code (pas les commentaires)
# ----------------------------------------------------------
$secretPatterns = @(

    # --- CONFIDENTIALITE CLIENT (Scope ALL - le nom du client ne doit JAMAIS
    # apparaitre en clair dans un fichier versionne, meme en prose libre dans
    # un README/CLAUDE.md - obligation de confidentialite ESN, y compris sur
    # un depot GitHub prive) ---
    @{ Pattern = 'Boursorama';                        Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Nom du client en clair - confidentialite ESN' },

    # --- CREDENTIALS (Scope ALL - critique partout) ---
    @{ Pattern = 'BOURSORAMA\\\\svc_';                Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Compte de service AD' },
    @{ Pattern = 'svc_pbvmwexp_\d+';                  Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Compte de service explicite' },
    @{ Pattern = 'adm_scharcho';                      Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Compte admin personnel' },
    @{ Pattern = 'Password\s*=\s*[''"][^''"]{4,}';   Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Mot de passe en clair' },
    @{ Pattern = '\$pass(word)?\s*=\s*[''"][^''"]{4,}'; Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Mot de passe en clair (variable $pass/$password)' },
    @{ Pattern = 'token\s*=\s*[''"][^''"]{8,}';      Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Token en clair' },

    # --- EMAILS (Scope ALL) ---
    @{ Pattern = '\w+@boursorama\.fr';                Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Email interne Boursorama' },
    @{ Pattern = 'architect-windows@';               Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Email équipe Windows' },
    @{ Pattern = 'sabri\.charchouf';                  Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'Email personnel' },

    # --- IPs SENSIBLES (Scope ALL) ---
    @{ Pattern = '192\.168\.5\.\d+';                  Niveau = 'CRITIQUE'; Scope = 'ALL';  Description = 'IP NFS Nutanix interne' },

    # --- INFRASTRUCTURE (Scope ALL) ---
    # Passe de CODE a ALL le 31/07/2026 : ces patterns exigent tous un ou
    # plusieurs chiffres (\d+), donc ne peuvent JAMAIS matcher un placeholder
    # generique de type <SERVEUR_REBOND> - restreindre au Scope CODE ne
    # supprimait aucun faux positif legitime, ca creait juste un angle mort
    # dans les commentaires. Preuve reelle dans un projet derive : "pwinfexpl001"
    # ecrit dans un commentaire d'en-tete de script, jamais detecte avant ce
    # correctif. Propage cette correction a tout projet qui a copie
    # Scan-Secrets.ps1 avant le 31/07/2026.
    @{ Pattern = 'pavcenter\d+\.boursorama\.fr';      Niveau = 'CRITIQUE'; Scope = 'ALL'; Description = 'Nom du vCenter Boursorama' },
    @{ Pattern = 'smtp\.\w+\.boursorama\.fr';         Niveau = 'CRITIQUE'; Scope = 'ALL'; Description = 'Serveur SMTP interne' },
    @{ Pattern = 'pwinfexpl\d+';                      Niveau = 'CRITIQUE'; Scope = 'ALL'; Description = 'Nom de serveur de rebond' },
    @{ Pattern = 'panutaclu\d+\.boursorama\.fr';      Niveau = 'CRITIQUE'; Scope = 'ALL'; Description = 'Cluster Nutanix réel' },
    @{ Pattern = 'paesxvsan\d+\.boursorama\.fr';      Niveau = 'CRITIQUE'; Scope = 'ALL'; Description = 'ESXi vSAN réel' },
    @{ Pattern = 'panutafla\w+\.boursorama\.fr';      Niveau = 'CRITIQUE'; Scope = 'ALL'; Description = 'ESXi Nutanix réel' },
    @{ Pattern = '(?<![_a-zA-Z])bo_met_\w+';         Niveau = 'CRITIQUE'; Scope = 'ALL'; Description = 'Nom de cluster réel Boursorama' },
    @{ Pattern = '10\.2\.\d+\.\d+';                   Niveau = 'ELEVE';    Scope = 'CODE'; Description = 'IP réseau interne Boursorama' },

    # --- GENERIQUES (Scope ALL) ---
    @{ Pattern = 'SecureString\s*\|';                 Niveau = 'ELEVE';    Scope = 'ALL';  Description = 'SecureString sérialisée' },
    @{ Pattern = '\b[A-Za-z0-9+/]{40,}={0,2}\b';     Niveau = 'MOYEN';    Scope = 'CODE'; Description = 'Chaîne Base64 longue (possible secret)' }
)

# ----------------------------------------------------------
# FICHIERS CRITIQUES - NE DOIVENT JAMAIS ÊTRE COMMITÉS
# (Vérification physique dans le répertoire - hors .gitignore)
# ----------------------------------------------------------
$fichiersCritiques = @(
    'aeskey*.txt',
    'credpassword*.txt',
    'global_params.ps1',
    '*.key',
    '*.pfx',
    '*.p12'
)

# ----------------------------------------------------------
# FICHIERS EXCLUS DU SCAN DE CONTENU
# ----------------------------------------------------------
$fichiersExclus = @(
    'Scan-Secrets.ps1',        # Contient les patterns - faux positifs garantis
    'config.ps1'               # Protégé par .gitignore
    # CHANGELOG.md volontairement RETIRE de cette liste le 31/07/2026 : une
    # entree "documentation historique" dans un projet derive contenait un
    # vrai nom de serveur de rebond, jamais detecte car ce fichier etait
    # exclu du scan de contenu. Aucun fichier de doc ne doit etre exempte
    # par defaut - propage cette correction a tout projet qui a copie
    # Scan-Secrets.ps1 avant le 31/07/2026.
)

# ----------------------------------------------------------
# LECTURE .GITIGNORE POUR EXCLURE LES FICHIERS PROTÉGÉS
# ----------------------------------------------------------
$rootPath = $PSScriptRoot
$gitignorePath = Join-Path $rootPath '.gitignore'
$gitignorePatterns = @()

if (Test-Path $gitignorePath) {
    $gitignorePatterns = Get-Content $gitignorePath |
        Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
}

Function Test-IsGitIgnored {
    Param([string]$FilePath)
    $relatif = $FilePath.Replace($rootPath, '').TrimStart('\').TrimStart('/').Replace('\', '/')
    foreach ($pattern in $gitignorePatterns) {
        $p = $pattern.Trim().TrimStart('/')

        if ($p.EndsWith('/')) {
            # Pattern de dossier (ex: '.claude/') -> exclut tout fichier sous ce dossier, à toute profondeur
            if ($relatif -like "$p*" -or $relatif -like "*/$p*") {
                return $true
            }
            continue
        }

        if ($relatif -like $p -or $relatif -like "*/$p" -or $relatif -eq $p) {
            return $true
        }
    }
    return $false
}

# ----------------------------------------------------------
# SCAN
# ----------------------------------------------------------
            $fichiers = Get-ChildItem -Path $rootPath -Recurse -File `
                -Include '*.ps1','*.txt','*.json','*.xml','*.cfg','*.ini','*.md' |
            Where-Object { $_.FullName -notmatch [regex]::Escape('\.git\') } |
            Where-Object { $_.FullName -notmatch [regex]::Escape('\.local-docs\') } |
            Where-Object { $fichiersExclus -notcontains $_.Name } |
            Where-Object { -not (Test-IsGitIgnored -FilePath $_.FullName) }

$totalAlertes = 0
$resultats    = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  SCAN SECRETS - TEMPLATE_BRS v1.5" -ForegroundColor Cyan
Write-Host "  Répertoire  : $rootPath" -ForegroundColor Cyan
Write-Host "  Fichiers    : $($fichiers.Count) analysés" -ForegroundColor Cyan
Write-Host "  Mode        : CODE+COMMENTAIRES pour credentials / CODE seul pour infra" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

# --- Vérification fichiers critiques (hors .gitignore) ---
Write-Host "--- Vérification fichiers critiques ---" -ForegroundColor Yellow

foreach ($pattern in $fichiersCritiques) {
    $trouves = Get-ChildItem -Path $rootPath -Recurse -File -Filter $pattern `
                   -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch [regex]::Escape('\.git\') }

    foreach ($fichier in $trouves) {
        # Ignorer si dans .gitignore
        if (Test-IsGitIgnored -FilePath $fichier.FullName) {
            if ($Verbose) {
                Write-Host "  [IGNORE] $($fichier.Name) - Protégé par .gitignore" -ForegroundColor Gray
            }
            continue
        }

        $relatif = $fichier.FullName.Replace($rootPath, '.')
        Write-Host "  [CRITIQUE] Fichier sensible non protégé : $relatif" -ForegroundColor Red
        $resultats.Add([PSCustomObject]@{
            Fichier     = $relatif
            Ligne       = 0
            Niveau      = 'CRITIQUE'
            Description = 'Fichier sensible non présent dans .gitignore'
            Extrait     = $fichier.Name
        })
        $totalAlertes++
    }
}

# --- Analyse contenu ---
Write-Host "`n--- Analyse du contenu ---" -ForegroundColor Yellow

foreach ($fichier in $fichiers) {
    $relatif = $fichier.FullName.Replace($rootPath, '.')
    $lignes  = @(Get-Content -Path $fichier.FullName -ErrorAction SilentlyContinue)
    if (-not $lignes) { continue }

    $alertesFichier = 0
    $inCommentBlock = $false

    for ($i = 0; $i -lt $lignes.Count; $i++) {
        $ligne = $lignes[$i]

        # Détection blocs commentaires PowerShell <# ... #>
        if ($ligne -match '<#') { $inCommentBlock = $true }
        if ($ligne -match '#>') { $inCommentBlock = $false; continue }

        # Ligne de commentaire simple ou dans un bloc
        $isComment = $inCommentBlock -or $ligne.Trim().StartsWith('#')

        foreach ($secret in $secretPatterns) {
            # Si commentaire ET scope CODE → ignorer (faux positif potentiel)
            if ($isComment -and $secret.Scope -eq 'CODE') { continue }

            if ($ligne -match $secret.Pattern) {

                $extrait = $ligne.Trim()
                if ($extrait.Length -gt 80) { $extrait = $extrait.Substring(0, 80) + '...' }

                $resultats.Add([PSCustomObject]@{
                    Fichier     = $relatif
                    Ligne       = $i + 1
                    Niveau      = $secret.Niveau
                    Description = $secret.Description
                    Extrait     = $extrait
                })
                $totalAlertes++
                $alertesFichier++

                $couleur = switch ($secret.Niveau) {
                    'CRITIQUE' { 'Red' }
                    'ELEVE'    { 'Yellow' }
                    default    { 'Cyan' }
                }

                if ($Verbose -or $secret.Niveau -eq 'CRITIQUE') {
                    $contexte = if ($isComment) { " [commentaire]" } else { "" }
                    Write-Host "  [$($secret.Niveau)] $relatif (L$($i+1))$contexte : $($secret.Description)" -ForegroundColor $couleur
                    if ($Verbose) {
                        Write-Host "    Extrait : $extrait" -ForegroundColor DarkGray
                    }
                }
            }
        }
    }

    if ($alertesFichier -gt 0 -and -not $Verbose) {
        Write-Host "  [ATTENTION] $relatif : $alertesFichier alerte(s)" -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------
# RAPPORT FINAL
# ----------------------------------------------------------
$critiques = ($resultats | Where-Object { $_.Niveau -eq 'CRITIQUE' }).Count
$eleves    = ($resultats | Where-Object { $_.Niveau -eq 'ELEVE'    }).Count
$moyens    = ($resultats | Where-Object { $_.Niveau -eq 'MOYEN'    }).Count

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  RAPPORT FINAL" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total alertes : $totalAlertes"  -ForegroundColor $(if ($totalAlertes -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "  CRITIQUE      : $critiques"     -ForegroundColor $(if ($critiques -eq 0) { 'Green' } else { 'Red' })
Write-Host "  ELEVE         : $eleves"        -ForegroundColor $(if ($eleves -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "  MOYEN         : $moyens"        -ForegroundColor $(if ($moyens -eq 0) { 'Green' } else { 'Cyan' })

if ($Fix -and $critiques -gt 0) {
    Write-Host "`n--- Corrections suggérées ---" -ForegroundColor Magenta
    Write-Host "  1. config.ps1 doit être dans .gitignore" -ForegroundColor White
    Write-Host "  2. Remplacer valeurs en dur par variables depuis config" -ForegroundColor White
    Write-Host "  3. Vérifier que aeskey_*.txt et credpassword_*.txt ne sont pas commités" -ForegroundColor White
    Write-Host "  4. Utiliser des placeholders dans BIN/ et FUNCTIONS/" -ForegroundColor White
}

if ($critiques -gt 0) {
    Write-Host "`n  [BLOQUE] $critiques alerte(s) CRITIQUE(s) - commit interdit" -ForegroundColor Red
    exit 1
} elseif ($totalAlertes -eq 0) {
    Write-Host "`n  [OK] Aucun secret détecté - commit autorisé" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n  [OK] Aucune alerte CRITIQUE - commit autorisé" -ForegroundColor Green
    Write-Host "  [INFO] $eleves alerte(s) ELEVE + $moyens MOYEN à surveiller" -ForegroundColor Yellow
    exit 0
}
