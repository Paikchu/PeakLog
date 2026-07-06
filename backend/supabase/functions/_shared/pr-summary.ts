export interface PRSnapshot {
  displayName?: string;
  maxWeight: number;
  weightUnit: string;
}

export interface PRCandidateExercise {
  normalizedName: string;
  displayName: string;
  maxWeight: number;
  weightUnit: string;
}

export interface PRSummaryItem {
  normalized_name: string;
  display_name: string;
  previous_weight: number | null;
  current_weight: number;
  weight_unit: string;
  is_new_record: boolean;
}

export interface PRSummaryResult {
  items: PRSummaryItem[];
  summaryText: string;
}

export interface PRSummaryBlock {
  type: "pr_summary";
  summary_text: string;
  items: PRSummaryItem[];
}

interface BuildPRSummaryArgs {
  previousPRs: Map<string, PRSnapshot>;
  currentPRs: Map<string, PRSnapshot>;
  candidateExercises: PRCandidateExercise[];
}

export function buildPRSummary({
  previousPRs,
  currentPRs,
  candidateExercises,
}: BuildPRSummaryArgs): PRSummaryResult {
  const uniqueCandidates = new Map<string, PRCandidateExercise>();
  for (const candidate of candidateExercises) {
    const existing = uniqueCandidates.get(candidate.normalizedName);
    if (!existing || candidate.maxWeight > existing.maxWeight) {
      uniqueCandidates.set(candidate.normalizedName, candidate);
    }
  }

  const items: PRSummaryItem[] = [];
  for (const candidate of uniqueCandidates.values()) {
    const previous = previousPRs.get(candidate.normalizedName);
    const current = currentPRs.get(candidate.normalizedName);
    if (!current) continue;

    const previousWeight = previous?.maxWeight ?? null;
    const isNewRecord = previousWeight == null || current.maxWeight > previousWeight;
    const candidateMatchesCurrent = current.maxWeight === candidate.maxWeight && current.weightUnit === candidate.weightUnit;
    if (!isNewRecord || !candidateMatchesCurrent) continue;

    items.push({
      normalized_name: candidate.normalizedName,
      display_name: current.displayName ?? candidate.displayName,
      previous_weight: previousWeight,
      current_weight: current.maxWeight,
      weight_unit: current.weightUnit,
      is_new_record: true,
    });
  }

  items.sort((lhs, rhs) => rhs.current_weight - lhs.current_weight || lhs.display_name.localeCompare(rhs.display_name));

  if (items.length === 0) {
    return {
      items,
      summaryText: "This workout didn't beat any existing PRs.",
    };
  }

  if (items.length === 1) {
    return {
      items,
      summaryText: `New PR: ${items[0].display_name} ${items[0].current_weight}${items[0].weight_unit}.`,
    };
  }

  return {
    items,
    summaryText: `New PRs in ${items.length} exercises this workout.`,
  };
}

export function buildPRSummaryBlock(summary: PRSummaryResult): PRSummaryBlock | null {
  if (summary.items.length === 0) {
    return null;
  }

  return {
    type: "pr_summary",
    summary_text: summary.summaryText,
    items: summary.items,
  };
}
