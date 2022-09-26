<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\ContiniousIntegrationScripts\ValueObject;

class Dependencies
{
    /** @var string */
    public $recipesEndpoint;

    /** @var ComposerPullRequestData[] */
    public $packages;

    /**
     * @param string $recipesEndpoint
     * @param ComposerPullRequestData[] $packages
     */
    public function __construct(string $recipesEndpoint, array $packages)
    {
        $this->recipesEndpoint = $recipesEndpoint;
        $this->packages = $packages;
    }
}
