<#
.SYNOPSIS
  Prepares the testbed fixture so the scanner has a git repo to diff against.

.DESCRIPTION
  The fixture is committed as plain source files, without its own git data, because a
  directory containing .git would be recorded by the parent repo as an embedded repo
  (mode 160000) and a clone would receive a broken pointer instead of the files.

  This script creates that git data locally: an initial commit representing the
  "before" state, with lib/data/ticket_repository.dart reverted to the baseline. That is
  what makes `impact_scan` see exactly one changed file and walk the whole chain from it.

  Run it once after cloning, or any time you want to reset the fixture.

.EXAMPLE
  pwsh -File testbed/reset_fixture.ps1
#>

$ErrorActionPreference = 'Stop'

$fixture = Join-Path $PSScriptRoot 'ticket_app'
$gitDir  = Join-Path $fixture '.git'

if (-not (Test-Path $fixture)) {
  throw "Fixture not found at $fixture"
}

Write-Host "Resetting fixture at $fixture"

# Remove leftover git data from a previous run.
if (Test-Path $gitDir) {
  Remove-Item $gitDir -Recurse -Force
}
$dotGit = Join-Path $fixture 'dot-git'
if (Test-Path $dotGit) {
  Remove-Item $dotGit -Recurse -Force
}

# Restore the "before" state of the file the AI is meant to have edited. The committed
# version already contains the change, so undo it here to recreate a clean baseline.
$repoFile = Join-Path $fixture 'lib\data\ticket_repository.dart'
@'
import '../models.dart';

/// The "API" layer. This is what the AI edits.
class TicketRepository {
  List<Ticket> getAllTickets() {
    return <Ticket>[
      const Ticket('1', 'Broken lift', null),
    ];
  }

  Future<void> markResolved(String id) async {}
}
'@ | Set-Content -Path $repoFile -Encoding utf8

# Initialise the repo and commit everything as the baseline.
Push-Location $fixture
try {
  git init -q
  git config user.email 'fixture@impact-radar.local'
  git config user.name  'impact radar fixture'
  git add -A
  git commit -q -m 'baseline before the AI edit'
  Write-Host ''
  Write-Host 'Fixture ready. Now apply the edit:'
  Write-Host '  1. add a searchTickets method to lib\data\ticket_repository.dart'
  Write-Host '  2. from the impact_radar root, run:'
  Write-Host '       dart run impact_radar:impact_scan --project testbed/ticket_app'
  Write-Host ''
  Write-Host 'Expected: tickets_screen.dart appears in the report, at depth 2 or deeper.'
}
finally {
  Pop-Location
}
