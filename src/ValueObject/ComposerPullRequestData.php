<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\Platform\ContiniousIntegrationScripts\ValueObject;

class ComposerPullRequestData
{
    /** @var string */
    public $requirement;

    /** @var string */
    public $repositoryUrl;

    /** @var string */
    public $package;
}
