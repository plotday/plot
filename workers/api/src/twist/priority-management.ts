import type { Database, SupabaseClient } from "@plotday/db";

/**
 * Gets or creates the "Plot" priority for a user.
 * This priority is created as a direct child of the user's root priority
 * and marked with key = '@plot' for easy identification.
 */
export async function getOrCreatePlotPriority(
  userId: string,
  supabase: SupabaseClient
): Promise<string> {
  // First, try to find existing Plot priority
  const existingResult = await supabase
    .from("priority_user")
    .select("priority_id")
    .eq("user_id", userId)
    .eq("key", "@plot")
    .maybeSingle();

  if (existingResult.error) {
    throw new Error(
      `Failed to query Plot priority: ${existingResult.error.message}`
    );
  }

  if (existingResult.data) {
    return existingResult.data.priority_id;
  }

  // Not found, need to create it
  // First get the user's root priority
  const rootResult = await supabase
    .from("priority_user")
    .select("priority_id, priority:priority_id(path)")
    .eq("user_id", userId)
    .eq("key", "root")
    .single();

  if (rootResult.error) {
    throw new Error(
      `Failed to find user root priority: ${rootResult.error.message}`
    );
  }

  const rootPath = (rootResult.data.priority as any).path;

  // Generate child path
  const pathResult = await supabase.rpc("generate_path", {
    parent: rootPath,
  });

  if (pathResult.error) {
    throw new Error(`Path generation failed: ${pathResult.error.message}`);
  }

  // Create the Plot priority
  const createResult = await supabase
    .from("priority")
    .insert({
      created_by: userId,
      title: "Plot",
      path: pathResult.data,
      updated_by: 0,
    })
    .select("id")
    .single();

  if (createResult.error) {
    throw new Error(
      `Failed to create Plot priority: ${createResult.error.message}`
    );
  }

  // Mark the priority_user entry with key = '@plot'
  // The insert_priority_user trigger already created a priority_user entry
  const { error: keyError } = await supabase
    .from("priority_user")
    .update({ key: "@plot" })
    .eq("user_id", userId)
    .eq("priority_id", createResult.data.id);

  if (keyError) {
    throw new Error(`Failed to set @plot key: ${keyError.message}`);
  }

  return createResult.data.id;
}

/**
 * Gets or creates the "Twist Development" priority for a user.
 * This priority is created as a direct child of the Plot priority
 * and marked with key = '@plot.twist-dev' for easy identification.
 */
export async function getOrCreateTwistDevelopmentPriority(
  userId: string,
  supabase: SupabaseClient
): Promise<string> {
  // First, try to find existing Twist Development priority
  const existingResult = await supabase
    .from("priority_user")
    .select("priority_id")
    .eq("user_id", userId)
    .eq("key", "@plot.twist-dev")
    .maybeSingle();

  if (existingResult.error) {
    throw new Error(
      `Failed to query twist development priority: ${existingResult.error.message}`
    );
  }

  if (existingResult.data) {
    return existingResult.data.priority_id;
  }

  // Not found, need to create it
  // First ensure the Plot priority exists
  const plotPriorityId = await getOrCreatePlotPriority(userId, supabase);

  // Get the Plot priority path
  const plotResult = await supabase
    .from("priority")
    .select("path")
    .eq("id", plotPriorityId)
    .single();

  if (plotResult.error) {
    throw new Error(
      `Failed to get Plot priority: ${plotResult.error.message}`
    );
  }

  // Generate child path
  const pathResult = await supabase.rpc("generate_path", {
    parent: plotResult.data.path,
  });

  if (pathResult.error) {
    throw new Error(`Path generation failed: ${pathResult.error.message}`);
  }

  // Create the Twist Development priority
  const createResult = await supabase
    .from("priority")
    .insert({
      created_by: userId,
      title: "Twist Development",
      path: pathResult.data,
      updated_by: 0,
    })
    .select("id")
    .single();

  if (createResult.error) {
    throw new Error(
      `Failed to create twist development priority: ${createResult.error.message}`
    );
  }

  // Mark the priority_user entry with key = '@plot.twist-dev'
  // The insert_priority_user trigger already created a priority_user entry
  const { error: keyError } = await supabase
    .from("priority_user")
    .update({ key: "@plot.twist-dev" })
    .eq("user_id", userId)
    .eq("priority_id", createResult.data.id);

  if (keyError) {
    throw new Error(
      `Failed to set @plot.twist-dev key: ${keyError.message}`
    );
  }

  return createResult.data.id;
}

/**
 * Gets or creates a priority for a specific twist deployment.
 * Uses twist_admin to find existing priorities by twist_package_id and isPersonal.
 * If not found, creates a new priority as a child of "Twist Development" and
 * creates a twist_admin entry for future lookups.
 */
export async function getOrCreateTwistPriority(
  userId: string,
  twistPackageId: string,
  twistName: string,
  isPersonal: boolean,
  supabase: SupabaseClient,
  publisherId?: number | null
): Promise<{ priorityId: string; twistAdminId: number; isNew: boolean }> {
  // Query twist_admin to see if this twist already has a priority
  const query = supabase
    .from("twist_admin")
    .select("id, priority_id")
    .eq("twist_package_id", twistPackageId);

  if (isPersonal) {
    query.eq("user_id", userId);
  } else {
    query.is("user_id", null);
  }

  const existingResult = await query.maybeSingle();

  if (existingResult.error) {
    throw new Error(
      `Failed to query twist_admin: ${existingResult.error.message}`
    );
  }

  if (existingResult.data?.priority_id) {
    return {
      priorityId: existingResult.data.priority_id,
      twistAdminId: existingResult.data.id,
      isNew: false,
    };
  }

  // Not found, need to create new priority and twist_admin entry
  // First ensure Twist Development priority exists
  const twistDevPriorityId = await getOrCreateTwistDevelopmentPriority(
    userId,
    supabase
  );

  // Get the Twist Development priority path
  const twistDevResult = await supabase
    .from("priority")
    .select("path, created_by")
    .eq("id", twistDevPriorityId)
    .single();

  if (twistDevResult.error) {
    throw new Error(
      `Failed to get twist development priority: ${twistDevResult.error.message}`
    );
  }

  // Generate child path
  const pathResult = await supabase.rpc("generate_path", {
    parent: twistDevResult.data.path,
  });

  if (pathResult.error) {
    throw new Error(`Path generation failed: ${pathResult.error.message}`);
  }

  // Create the twist-specific priority
  const priorityTitle = isPersonal ? `${twistName} (Personal)` : twistName;
  const createPriorityResult = await supabase
    .from("priority")
    .insert({
      created_by: twistDevResult.data.created_by,
      title: priorityTitle,
      path: pathResult.data,
      updated_by: 0,
    })
    .select("id")
    .single();

  if (createPriorityResult.error) {
    throw new Error(
      `Failed to create twist priority: ${createPriorityResult.error.message}`
    );
  }

  const priorityId = createPriorityResult.data.id;

  // Create or update twist_admin entry
  if (existingResult.data) {
    // twist_admin exists but priority_id was null - update it
    const updateResult = await supabase
      .from("twist_admin")
      .update({ priority_id: priorityId })
      .eq("id", existingResult.data.id)
      .select("id")
      .single();

    if (updateResult.error) {
      throw new Error(
        `Failed to update twist_admin: ${updateResult.error.message}`
      );
    }

    return {
      priorityId,
      twistAdminId: updateResult.data.id,
      isNew: true,
    };
  } else {
    // Create new twist_admin entry
    const twistAdminData: Database["public"]["Tables"]["twist_admin"]["Insert"] =
      {
        twist_package_id: twistPackageId,
        priority_id: priorityId,
      };

    if (isPersonal) {
      twistAdminData.user_id = userId;
    } else {
      // For non-personal, we need a publisher_id to satisfy the ownership check constraint
      if (publisherId === undefined || publisherId === null) {
        throw new Error(
          "Publisher ID is required for non-personal twist deployments"
        );
      }
      twistAdminData.publisher_id = publisherId;
    }

    const createAdminResult = await supabase
      .from("twist_admin")
      .insert(twistAdminData)
      .select("id")
      .single();

    if (createAdminResult.error) {
      throw new Error(
        `Failed to create twist_admin: ${createAdminResult.error.message}`
      );
    }

    return {
      priorityId,
      twistAdminId: createAdminResult.data.id,
      isNew: true,
    };
  }
}

/**
 * Gets all publishers that the user has access to.
 * Returns publishers from twist_admin entries where the user has access to the priority.
 */
export async function getAccessiblePublishers(
  userId: string,
  supabase: SupabaseClient
): Promise<Array<{ id: number; name: string; email: string | null; url: string | null }>> {
  // Get publishers from twist_admin where priority_id is accessible
  // We query twist_admin entries that have a publisher and priority
  const result = await supabase
    .from("twist_admin")
    .select(
      `
      publisher:publisher_id (
        id,
        name,
        email,
        url
      )
    `
    )
    .not("publisher_id", "is", null)
    .not("priority_id", "is", null);

  if (result.error) {
    throw new Error(`Failed to get publishers: ${result.error.message}`);
  }

  // Filter to unique publishers
  const publishers = new Map<
    number,
    { id: number; name: string; email: string | null; url: string | null }
  >();

  for (const row of result.data) {
    const publisher = row.publisher as any;
    if (publisher && !publishers.has(publisher.id)) {
      publishers.set(publisher.id, publisher);
    }
  }

  return Array.from(publishers.values());
}

/**
 * Creates a new publisher record.
 */
export async function createPublisher(
  name: string,
  url: string | null,
  supabase: SupabaseClient
): Promise<{ id: number; name: string; email: string | null; url: string | null }> {
  const result = await supabase
    .from("publisher")
    .insert({
      name,
      url,
    })
    .select("id, name, email, url")
    .single();

  if (result.error) {
    throw new Error(`Failed to create publisher: ${result.error.message}`);
  }

  return result.data;
}
